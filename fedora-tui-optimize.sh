#!/usr/bin/env bash
set -euo pipefail

# ===== Settings & Variables =====
LOG_FILE="${LOG_FILE:-/var/log/fedora-clean-optimize.log}"
DEFAULT_VACUUM="7d"

# ===== Helpers =====
log() { echo -e "[\e[1;34mINFO\e[0m] $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "[\e[1;33mWARN\e[0m] $*" | tee -a "$LOG_FILE"; }
err() { echo -e "[\e[1;31mERR \e[0m] $*" | tee -a "$LOG_FILE" >&2; }

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "[\e[1;31mERR\e[0m] กรุณาเรียกใช้งานด้วย sudo หรือ root"
    exit 1
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

if have dnf5; then PKG="dnf5"; else PKG="dnf"; fi

# ===== Pre-flight Checks =====
need_root

if ! have whiptail; then
  echo "ระบบไม่พบ 'whiptail' กำลังติดตั้ง newt ให้โดยอัตโนมัติ..."
  $PKG install -y newt
fi

# ===== TUI Menu =====
CHOICES=$(whiptail --title "Fedora Clean & Optimize (TUI)" \
  --checklist "เลือกรายการที่ต้องการดำเนินการ (กด Spacebar เพื่อเลือก/ยกเลิก, Enter เพื่อตกลง):" 21 82 7 \
  "1_CHECK"      "ตรวจสอบอัปเดต (dnf check-update)" ON \
  "2_UPGRADE"    "อัปเดตระบบ (dnf upgrade)" OFF \
  "3_AUTOREMOVE" "ลบแพ็กเกจที่ไม่ใช้ (dnf autoremove)" OFF \
  "4_JOURNAL"    "ล้าง Log เก่า (journalctl)" OFF \
  "5_FSTRIM"     "Trim SSD/NVMe (fstrim)" OFF \
  "6_FLATPAK"    "อัปเดตและล้าง Flatpak" OFF \
  "7_KERNELS"    "จัดการลบ Kernel เก่า" OFF \
  3>&1 1>&2 2>&3) || exit 0

if [ -z "$CHOICES" ]; then
  echo "ยกเลิกการทำงาน"
  exit 0
fi

VACUUM_TIME=$DEFAULT_VACUUM
if [[ $CHOICES == *"4_JOURNAL"* ]]; then
  VACUUM_TIME=$(whiptail --title "Journal Vacuum Time" \
    --inputbox "กำหนดอายุของ log ที่ต้องการเก็บไว้ (เช่น 7d, 30d):" 10 60 "$DEFAULT_VACUUM" \
    3>&1 1>&2 2>&3) || exit 0
fi

# ===== Execution =====
clear
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

echo "========================================"
log "เริ่มดำเนินการ Clean & Optimize (บันทึก log ที่: $LOG_FILE)"
echo "========================================"

if [[ $CHOICES == *"1_CHECK"* ]]; then
  log "ตรวจสอบการอัปเดตแพ็กเกจ..."
  $PKG check-update --refresh || true
  echo "----------------------------------------"
fi

if [[ $CHOICES == *"2_UPGRADE"* ]]; then
  log "อัปเดตแพ็กเกจทั้งหมด..."
  $PKG upgrade --refresh -y || err "upgrade บางส่วนล้มเหลว (จะข้ามไปขั้นตอนต่อไป)"
  echo "----------------------------------------"
fi

if [[ $CHOICES == *"3_AUTOREMOVE"* ]]; then
  log "ลบแพ็กเกจที่ไม่ใช้งาน (autoremove)..."
  $PKG autoremove -y || true
  echo "----------------------------------------"
fi

if [[ $CHOICES == *"4_JOURNAL"* ]]; then
  if have journalctl; then
    log "ล้าง journal log ที่เก่ากว่า $VACUUM_TIME..."
    journalctl --vacuum-time="$VACUUM_TIME" || warn "vacuum journal ไม่สำเร็จ"
  fi
  echo "----------------------------------------"
fi

if [[ $CHOICES == *"5_FSTRIM"* ]]; then
  if have fstrim; then
    log "รัน fstrim -av (trim SSD/NVMe)..."
    fstrim -av || warn "fstrim ไม่สำเร็จ"
  else
    warn "ไม่มีคำสั่ง fstrim"
  fi
  echo "----------------------------------------"
fi

if [[ $CHOICES == *"6_FLATPAK"* ]]; then
  if have flatpak; then
    log "อัปเดต Flatpak..."
    flatpak update -y || warn "flatpak update มีบางรายการไม่สำเร็จ"
    log "ลบ Flatpak ที่ไม่ถูกใช้งาน..."
    flatpak uninstall --unused -y || true
  else
    warn "ไม่มีคำสั่ง flatpak"
  fi
  echo "----------------------------------------"
fi

if [[ $CHOICES == *"7_KERNELS"* ]]; then
  log "ตรวจสอบ Kernel ในระบบ..."
  RUNNING_VRARCH="$(uname -r)"
  RUNNING_NEVRA="kernel-core-${RUNNING_VRARCH}"
  
  # ดึงรายการ kernel-core ที่ติดตั้งไว้เรียงตามเวอร์ชัน (เก่าไปใหม่)
  mapfile -t KERNEL_CORES < <(rpm -q kernel-core --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort -V || true)
  TOTAL=${#KERNEL_CORES[@]}
  
  if [[ $TOTAL -le 1 ]]; then
    log "มี Kernel ในระบบเพียง 1 รุ่น (ไม่มีรุ่นเก่าให้ลบ)"
  else
    WHIPTAIL_ARGS=()
    # สร้างรายการสำหรับ Checklist
    for (( i=0; i<TOTAL; i++ )); do
      NEVRA="${KERNEL_CORES[$i]}"
      STATUS="ON" # ค่าเริ่มต้นคือ "เลือกเพื่อลบ"
      DESC="[เก่า]"

      if [[ "$NEVRA" == "$RUNNING_NEVRA" ]]; then
        DESC="[Active/ใช้งานอยู่] *ป้องกันการลบอัตโนมัติ*"
        STATUS="OFF" # ไม่ให้ติ๊กลบ
      elif [[ $i -ge $((TOTAL - 2)) ]]; then
        DESC="[ล่าสุด] *แนะนำให้เก็บไว้ 2 รุ่น*"
        STATUS="OFF" # ไม่ให้ติ๊กลบ
      fi

      WHIPTAIL_ARGS+=("$NEVRA" "$DESC" "$STATUS")
    done

    # แสดงหน้าต่าง TUI สำหรับเลือก Kernel
    KERNEL_CHOICES=$(whiptail --title "จัดการ Kernel (เลือกรุ่นที่ต้องการลบ)" \
      --checklist "คำแนะนำ: ควรเก็บ Kernel 2 รุ่นล่าสุดเอาไว้เผื่อฉุกเฉิน\n(ระบบจะบังคับไม่ให้ลบตัวที่ Active อยู่เสมอ)\n\nกด Spacebar เพื่อติ๊ก [ลบ] หรือ [ไม่ลบ]:" \
      22 85 8 "${WHIPTAIL_ARGS[@]}" 3>&1 1>&2 2>&3) || true

    if [ -n "$KERNEL_CHOICES" ]; then
      PKGS_TO_REMOVE=()
      
      # แปลง String จาก whiptail ให้อยู่ในรูป Array
      eval "selected_kernels=($KERNEL_CHOICES)"

      for core_nevra in "${selected_kernels[@]}"; do
        # ตัวป้องกันหลังบ้าน (ดักไว้เผื่อผู้ใช้ฝืนติ๊กลบตัว Active)
        if [[ "$core_nevra" == "$RUNNING_NEVRA" ]]; then
          warn "ข้ามการลบ $core_nevra เนื่องจากระบบกำลังใช้งานอยู่ (Active)"
          continue
        fi

        vrarch="${core_nevra#kernel-core-}"
        while IFS= read -r p; do
          PKGS_TO_REMOVE+=("$p")
        done < <(rpm -qa | grep -E '^kernel(-(core|modules|modules-extra|devel|devel-matched))?-' | grep -F "$vrarch" || true)
      done
      
      if [[ ${#PKGS_TO_REMOVE[@]} -gt 0 ]]; then
        mapfile -t PKGS_TO_REMOVE < <(printf '%s\n' "${PKGS_TO_REMOVE[@]}" | sort -u)
        log "กำลังลบแพ็กเกจ Kernel ทั้งหมด ${#PKGS_TO_REMOVE[@]} รายการ..."
        $PKG remove -y "${PKGS_TO_REMOVE[@]}" || warn "การลบ Kernel บางแพ็กเกจล้มเหลว"
      else
        log "ไม่มี Kernel ที่ต้องลบ หรือคุณเลือกเฉพาะตัวที่ Active เอาไว้"
      fi
    else
      log "ข้ามการลบ Kernel (ไม่ได้เลือกรายการใดๆ)"
    fi
  fi
  echo "----------------------------------------"
fi

log "เสร็จสมบูรณ์ ✅"

whiptail --title "การทำงานเสร็จสิ้น" \
  --msgbox "ดำเนินการตามที่เลือกเสร็จเรียบร้อยแล้ว!\n\nหากมีการอัปเดต/ลบ Kernel แนะนำให้ Reboot ระบบเมื่อสะดวก\n\nดู Log ได้ที่: $LOG_FILE" 12 60
