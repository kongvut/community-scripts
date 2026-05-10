#!/usr/bin/env bash
set -euo pipefail

# ===== Settings & Variables =====
LOG_FILE="${LOG_FILE:-/var/log/arch-clean-optimize.log}"
DEFAULT_VACUUM="7d"
REAL_USER="${SUDO_USER:-}"

# ===== Helpers =====
log() { echo -e "[\e[1;34mINFO\e[0m] $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "[\e[1;33mWARN\e[0m] $*" | tee -a "$LOG_FILE"; }
err() { echo -e "[\e[1;31mERR \e[0m] $*" | tee -a "$LOG_FILE" >&2; }

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "[\e[1;31mERR\e[0m] โปรดรันสคริปต์นี้ด้วย sudo (อย่ารันด้วย root โดยตรง หากต้องการอัปเดต AUR)"
    exit 1
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

run_as_user() {
  if [ -n "$REAL_USER" ]; then
    sudo -u "$REAL_USER" "$@"
  else
    warn "ไม่สามารถรัน '$1' ได้เนื่องจากไม่ทราบ User เริ่มต้น"
  fi
}

# ฟังก์ชันคำนวณวันอัปเดตล่าสุด (ปรับปรุงใหม่ให้แม่นยำขึ้น)
get_last_update_msg() {
  local last_epoch=""

  # 1. ลองหาจากประวัติ full system upgrade ใน pacman.log ก่อน
  if [ -f /var/log/pacman.log ]; then
    local last_date_str
    last_date_str=$(grep -a "starting full system upgrade" /var/log/pacman.log | tail -n 1 | grep -oP '^\[\K[^\]]+' || true)
    
    if [ -n "$last_date_str" ]; then
      last_epoch=$(date -d "$last_date_str" +%s 2>/dev/null || true)
    fi
  fi

  # 2. ถ้าหาใน Log ไม่เจอ ให้ดูจากวันที่แก้ไขฐานข้อมูลแพ็กเกจ (แม่นยำและอิงตามจริง)
  if [ -z "$last_epoch" ] && [ -d /var/lib/pacman/local ]; then
    last_epoch=$(stat -c %Y /var/lib/pacman/local 2>/dev/null || true)
  fi

  if [ -n "$last_epoch" ]; then
    local current_epoch
    current_epoch=$(date +%s)
    local days=$(( (current_epoch - last_epoch) / 86400 ))
    
    if [ "$days" -ge 14 ]; then
      echo "อัปเดตล่าสุด: $days วันที่แล้ว (⚠️ เกิน 2 สัปดาห์ แนะนำให้อัปเดต!)"
    elif [ "$days" -eq 0 ]; then
      echo "อัปเดตล่าสุด: วันนี้ (✅ ระบบได้รับการดูแลแล้ว)"
    else
      echo "อัปเดตล่าสุด: $days วันที่แล้ว (✅ ยังอยู่ในเกณฑ์ 2 สัปดาห์)"
    fi
  else
    echo "อัปเดตล่าสุด: ไม่สามารถประเมินได้"
  fi
}

# ===== Pre-flight Checks =====
need_root

if ! have whiptail; then
  echo "ไม่พบคำสั่ง 'whiptail' กำลังเตรียมติดตั้ง 'libnewt'..."
  pacman -Sy libnewt
fi

HAVE_YAY=false
if have yay; then
  HAVE_YAY=true
fi

UPDATE_MSG=$(get_last_update_msg)

# ===== TUI Menu =====
CHOICES=$(whiptail --title "Arch Linux Maintenance (TUI)" \
  --checklist "$UPDATE_MSG\n\nเลือกรายการที่ต้องการ (Spacebar เพื่อเลือก, Enter เพื่อตกลง):" 24 85 9 \
  "1_CHECK"      "[ อัปเดต ] ตรวจสอบอัปเดต (Check only)" ON \
  "2_UPGRADE"    "[ อัปเดต ] อัปเดตระบบและ AUR (pacman & yay)" OFF \
  "3_FIRMWARE"   "[ อัปเดต ] อัปเดตเฟิร์มแวร์ (fwupdmgr)" OFF \
  "4_FLATPAK"    "[ อัปเดต ] อัปเดตและเคลียร์ Flatpak" OFF \
  "5_ORPHANS"    "[ ล้างขยะ ] ลบแพ็กเกจที่ไม่ได้ใช้งาน (Orphans)" OFF \
  "6_CACHE"      "[ ล้างขยะ ] ล้างแคชแพ็กเกจ (pacman & yay)" OFF \
  "7_JOURNAL"    "[ ล้างขยะ ] ล้าง Log ของระบบ (journalctl)" OFF \
  "8_FSTRIM"     "[ บำรุงรักษา ] ทำความสะอาด SSD (fstrim)" OFF \
  3>&1 1>&2 2>&3) || exit 0

if [ -z "$CHOICES" ]; then
  echo "ยกเลิกการทำงาน"
  exit 0
fi

VACUUM_TIME=$DEFAULT_VACUUM
if [[ $CHOICES == *"7_JOURNAL"* ]]; then
  VACUUM_TIME=$(whiptail --title "Journal Vacuum Time" \
    --inputbox "กำหนดอายุของ Log ที่ต้องการเก็บไว้ (เช่น 7d, 30d):" 10 60 "$DEFAULT_VACUUM" \
    3>&1 1>&2 2>&3) || exit 0
fi

# ===== Execution =====
clear
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

echo "========================================"
log "เริ่มกระบวนการบำรุงรักษาระบบ (บันทึก Log ที่: $LOG_FILE)"
echo "========================================"

if [[ $CHOICES == *"1_CHECK"* ]]; then
  log "กำลังซิงก์ฐานข้อมูลแพ็กเกจ..."
  pacman -Sy || true
  
  echo "แพ็กเกจระบบที่สามารถอัปเดตได้:"
  pacman -Qu || echo "- ระบบเป็นปัจจุบันแล้ว"
  
  if $HAVE_YAY; then
    echo "แพ็กเกจ AUR ที่สามารถอัปเดตได้:"
    run_as_user yay -Qua || echo "- AUR เป็นปัจจุบันแล้ว"
  fi
  echo "----------------------------------------"
fi

if [[ $CHOICES == *"2_UPGRADE"* ]]; then
  log "กำลังอัปเดตแพ็กเกจระบบหลัก..."
  pacman -Syu || err "การอัปเดตระบบหลักล้มเหลว"
  
  if $HAVE_YAY; then
    log "กำลังอัปเดตแพ็กเกจ AUR..."
    run_as_user yay -Sua || warn "การอัปเดต AUR บางส่วนล้มเหลว"
  fi
  echo "----------------------------------------"
fi

if [[ $CHOICES == *"3_FIRMWARE"* ]]; then
  log "กำลังตรวจสอบและอัปเดตเฟิร์มแวร์ (fwupdmgr)..."
  if have fwupdmgr; then
    fwupdmgr refresh --force && fwupdmgr get-updates && fwupdmgr update || warn "ไม่มีเฟิร์มแวร์ให้อัปเดต หรือเกิดข้อผิดพลาด"
  else
    warn "ไม่พบคำสั่ง fwupdmgr (อาจไม่ได้ติดตั้งแพ็กเกจ fwupd)"
  fi
  echo "----------------------------------------"
fi

if [[ $CHOICES == *"4_FLATPAK"* ]]; then
  if have flatpak; then
    log "กำลังอัปเดต Flatpak..."
    flatpak update || warn "อัปเดต Flatpak บางรายการไม่สำเร็จ"
    log "เคลียร์ Flatpak ที่ไม่ถูกใช้งาน..."
    flatpak uninstall --unused || true
  else
    warn "ไม่มีคำสั่ง flatpak"
  fi
  echo "----------------------------------------"
fi

if [[ $CHOICES == *"5_ORPHANS"* ]]; then
  log "ค้นหาและลบแพ็กเกจที่ไม่ได้ใช้งาน (Orphans)..."
  ORPHANS=$(pacman -Qdtq || true)
  if [ -n "$ORPHANS" ]; then
    log "พบแพ็กเกจตกค้าง กำลังดำเนินการลบ..."
    echo "$ORPHANS" | pacman -Rns - || warn "ไม่สามารถลบแพ็กเกจตกค้างบางรายการได้"
  else
    log "ระบบสะอาดดี ไม่พบแพ็กเกจตกค้าง"
  fi
  echo "----------------------------------------"
fi

if [[ $CHOICES == *"6_CACHE"* ]]; then
  log "กำลังจัดการแคชของแพ็กเกจ..."
  
  # แก้ปัญหา Error: ลบไฟล์ชั่วคราวและไฟล์ดาวน์โหลดที่ตกค้างออกด้วย rm ตรงๆ
  log "เคลียร์ไฟล์ดาวน์โหลดที่ตกค้าง เพื่อป้องกัน Error..."
  rm -f /var/cache/pacman/pkg/download-* 2>/dev/null || true
  rm -f /var/cache/pacman/pkg/*.part 2>/dev/null || true
  
  if have paccache; then
    log "รัน paccache (เก็บ 2 เวอร์ชันล่าสุดไว้)..."
    paccache -r -k 2 || warn "รัน paccache ล้มเหลว"
    log "ลบแคชของแพ็กเกจที่ถูกถอดถอนไปแล้ว..."
    paccache -ruk0 || true
  else
    log "ใช้คำสั่งพื้นฐาน pacman -Sc..."
    pacman -Sc || warn "ล้างแคชแพ็กเกจไม่สำเร็จ"
  fi

  if $HAVE_YAY; then
    log "ล้างแคชแพ็กเกจใน AUR (yay)..."
    run_as_user yay -Sc --aur || warn "ล้างแคช yay ไม่สำเร็จ"
  fi
  echo "----------------------------------------"
fi

if [[ $CHOICES == *"7_JOURNAL"* ]]; then
  if have journalctl; then
    log "ล้าง Log ที่เก่ากว่า $VACUUM_TIME..."
    journalctl --vacuum-time="$VACUUM_TIME" || warn "ล้าง Journal ไม่สำเร็จ"
  fi
  echo "----------------------------------------"
fi

if [[ $CHOICES == *"8_FSTRIM"* ]]; then
  if have fstrim; then
    log "กำลังรัน fstrim -av (ทำความสะอาด SSD/NVMe)..."
    fstrim -av || warn "รัน fstrim ไม่สำเร็จ"
  else
    warn "ไม่มีคำสั่ง fstrim"
  fi
  echo "----------------------------------------"
fi

log "ทำงานเสร็จสมบูรณ์ ✅"

whiptail --title "การทำงานเสร็จสิ้น" \
  --msgbox "ดำเนินการตามที่คุณเลือกเสร็จเรียบร้อยแล้ว!\n\nหากมีการอัปเดต Kernel หรือเฟิร์มแวร์ แนะนำให้รีบูตระบบเมื่อสะดวก\n\nสามารถตรวจสอบ Log ได้ที่: $LOG_FILE" 12 60
