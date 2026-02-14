#!/bin/bash

# กำหนดตัวแปร Path และ URL
WINE_PREFIX_DIR="$HOME/.wineprefixes/line"
LINE_INSTALLER_URL="https://desktop.line-scdn.net/win/new/LineInst.exe"
LINE_INSTALLER_PATH="/tmp/LineInst.exe"

# สีสำหรับแสดงผล
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ฟังก์ชันแสดง Header
function show_header {
    clear
    echo -e "${BLUE}=========================================${NC}"
    echo -e "${BLUE}    LINE Installer for Linux (Wine)      ${NC}"
    echo -e "${BLUE}=========================================${NC}"
}

# ฟังก์ชันจัดการการติดตั้ง Wine (Step 0-1)
function install_wine_system {
    PACKAGE_MANAGER=$1
    echo -e "${YELLOW}กำลังเริ่มขั้นตอนการลบ Wine เก่าและติดตั้งใหม่...${NC}"
    
    if [ "$PACKAGE_MANAGER" == "dnf" ]; then
        # Fedora
        echo -e "${RED}[Step 0] Removing old wine (Fedora)...${NC}"
        sudo dnf remove "wine*" -y
        
        echo -e "${GREEN}[Step 1] Installing Wine & Winetricks (Fedora)...${NC}"
        sudo dnf install wine winecfg wine-alsa wine-pulseaudio winetricks wget -y
        
    elif [ "$PACKAGE_MANAGER" == "apt" ]; then
        # Debian/Ubuntu
        echo -e "${RED}[Step 0] Removing old wine (Ubuntu/Debian)...${NC}"
        sudo apt remove "wine*" --purge -y
        sudo apt autoremove -y
        
        echo -e "${GREEN}[Step 1] Installing Wine & Winetricks (Ubuntu/Debian)...${NC}"
        sudo dpkg --add-architecture i386
        sudo apt update
        sudo apt install wine wine32 wine64 winetricks pulseaudio wget -y
    fi
    
    echo -e "${GREEN}ตรวจสอบเวอร์ชัน Wine:${NC}"
    wine --version
    echo -e "${YELLOW}กด Enter เพื่อกลับสู่เมนู...${NC}"
    read
}

# ฟังก์ชันตั้งค่า Environment (Step 2-5)
function setup_line_env {
    echo -e "${GREEN}[Step 2] Creating Wine Prefix at $WINE_PREFIX_DIR ...${NC}"
    mkdir -p "$WINE_PREFIX_DIR"

    echo -e "${GREEN}[Step 3] Configuring Wine (Winecfg)...${NC}"
    echo -e "${YELLOW}>>> กรุณาตั้งค่าดังนี้ในหน้าต่างที่เด้งขึ้นมา:${NC}"
    echo -e "    1. Application Tab: เลือก Windows Version เป็น ${BLUE}Windows 11${NC}"
    echo -e "    2. Audio Tab: ตรวจสอบว่าเป็น ${BLUE}PulseAudio${NC}"
    echo -e "    3. กด OK เพื่อบันทึก"
    WINEPREFIX="$WINE_PREFIX_DIR" winecfg

    echo -e "${GREEN}[Step 4] Installing Core Fonts & Dependencies...${NC}"
    echo -e "${YELLOW}ขั้นตอนนี้อาจใช้เวลาสักพักและอาจมีหน้าต่างเด้งขึ้นมา ให้กด Install ไปเรื่อยๆ${NC}"
    
    # Corefonts
    WINEPREFIX="$WINE_PREFIX_DIR" winetricks -q corefonts
    
    # VCRUN2022 (Visual C++ Redistributable)
    echo -e "${BLUE}Installing vcrun2022...${NC}"
    WINEPREFIX="$WINE_PREFIX_DIR" winetricks -q vcrun2022
    
    # OpenAL
    echo -e "${BLUE}Installing openal...${NC}"
    WINEPREFIX="$WINE_PREFIX_DIR" winetricks -q openal

    # Restart Wine server inside prefix
    WINEPREFIX="$WINE_PREFIX_DIR" wineboot -r

    echo -e "${GREEN}[Step 5] Downloading & Installing LINE...${NC}"
    if [ -f "$LINE_INSTALLER_PATH" ]; then
        rm "$LINE_INSTALLER_PATH"
    fi
    
    wget -O "$LINE_INSTALLER_PATH" "$LINE_INSTALLER_URL"
    
    echo -e "${YELLOW}กำลังเปิดตัวติดตั้ง LINE... กรุณาติดตั้งตามปกติ${NC}"
    WINEPREFIX="$WINE_PREFIX_DIR" wine "$LINE_INSTALLER_PATH"
    
    echo -e "${GREEN}การติดตั้งเสร็จสิ้น!${NC}"
    echo -e "${YELLOW}กด Enter เพื่อกลับสู่เมนู...${NC}"
    read
}

# ฟังก์ชัน Reset (Step 6)
function reset_prefix {
    echo -e "${RED}[WARNING] คุณกำลังจะลบ Wine Prefix ของ LINE ($WINE_PREFIX_DIR)${NC}"
    echo -e "${RED}ข้อมูลแชทและประวัติในเครื่องนี้จะหายไปทั้งหมด!${NC}"
    read -p "คุณแน่ใจหรือไม่? (y/N): " confirm
    if [[ $confirm == [yY] || $confirm == [yY][eE][sS] ]]; then
        echo -e "${RED}Deleting...${NC}"
        rm -rf "$WINE_PREFIX_DIR"
        echo -e "${GREEN}ลบเรียบร้อยแล้ว คุณสามารถเลือกเมนูติดตั้งใหม่ได้ทันที${NC}"
    else
        echo -e "${YELLOW}ยกเลิกการลบ${NC}"
    fi
    read -p "กด Enter เพื่อกลับ..."
}

# ฟังก์ชัน Kill Process (Step 7)
function kill_process {
    echo -e "${YELLOW}Killing Wine processes for LINE prefix...${NC}"
    WINEPREFIX="$WINE_PREFIX_DIR" wineboot -k
    echo -e "${GREEN}Processes killed.${NC}"
    sleep 1
}

# เมนูหลัก
while true; do
    show_header
    echo "1) ติดตั้ง System Wine (Fedora/DNF)"
    echo "2) ติดตั้ง System Wine (Ubuntu/Debian/APT)"
    echo "3) ตั้งค่า Wine Prefix และติดตั้ง LINE (ทำหลังจากข้อ 1 หรือ 2)"
    echo "4) เปิดโปรแกรม LINE (Run)"
    echo "5) บังคับปิดโปรแกรม (Kill Process)"
    echo "6) ล้างค่าติดตั้ง LINE ทั้งหมด (Remove Prefix)"
    echo "0) ออกจากโปรแกรม"
    echo -e "${BLUE}-----------------------------------------${NC}"
    read -p "เลือกเมนู [0-6]: " choice

    case $choice in
        1)
            install_wine_system "dnf"
            ;;
        2)
            install_wine_system "apt"
            ;;
        3)
            setup_line_env
            ;;
        4)
            echo -e "${GREEN}Starting LINE...${NC}"
            # พยายามหา Path ที่ LINE ติดตั้งไป (ปกติจะอยู่ที่นี่)
            LINE_EXE="$WINE_PREFIX_DIR/drive_c/users/$USER/AppData/Local/LINE/bin/LineLauncher.exe"
            
            if [ ! -f "$LINE_EXE" ]; then
                 # ลองหาที่ Program Files ถ้าไม่เจอใน AppData
                 LINE_EXE="$WINE_PREFIX_DIR/drive_c/Program Files (x86)/LINE/LineLauncher.exe"
            fi

            if [ -f "$LINE_EXE" ]; then
                WINEPREFIX="$WINE_PREFIX_DIR" wine "$LINE_EXE" &
            else
                echo -e "${RED}ไม่พบไฟล์ LineLauncher.exe กรุณาตรวจสอบการติดตั้ง${NC}"
                read -p "กด Enter เพื่อกลับ..."
            fi
            ;;
        5)
            kill_process
            ;;
        6)
            reset_prefix
            ;;
        0)
            echo "Bye!"
            exit 0
            ;;
        *)
            echo -e "${RED}เลือกผิด กรุณาเลือกใหม่${NC}"
            sleep 1
            ;;
    esac
done
