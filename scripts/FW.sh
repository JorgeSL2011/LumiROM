#!/bin/bash

DOWNLOAD_FIRMWARE() {
    if [ "$#" -lt 2 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <DOWNLOAD_DIRECTORY> <GOFILE_DIRECT_URL>"
        return 1
    fi

    # Usamos rutas absolutas basadas en lo que le pases por argumento (FIRM_DIR)
    local BASE_DIR="$1"
    local GOFILE_URL="$2"
    
    # 1. Limpieza rigurosa de la URL para evitar el bug "otIith"
    local CLEAN_URL="${GOFILE_URL%%\?*}"
    local FILE_NAME="${CLEAN_URL##*/}"
    
    # 2. Forzar el nombre del modelo basado en el STOCK_DEVICE si la URL viene corrupta
    local MODEL="$STOCK_DEVICE"
    if [[ -n "$FILE_NAME" && "$FILE_NAME" == *"_*.zip" ]]; then
        # Si el zip tiene el formato estándar (ej: SM-A346B.zip), extrae el modelo
        MODEL="${FILE_NAME%.zip}"
    fi

    # Definimos la ruta de descarga exacta bajo el directorio absoluto
    local DOWN_DIR="${BASE_DIR}/${MODEL}"
    
    rm -rf "$DOWN_DIR"
    mkdir -p "$DOWN_DIR"

    echo -e "========================================"
    echo -e "   GitHub Actions FW Downloader & Unzip "
    echo -e "========================================"
    echo -e "FIRM_DIR: $BASE_DIR"
    echo -e "TARGET MODEL: $MODEL"
    echo -e "SAVING TO: ${DOWN_DIR}/${MODEL}.zip"

    # Exportar variables globales corregidas con rutas absolutas para el runner
    export TARGET_DEVICE="$MODEL"
    if [ -n "$GITHUB_ENV" ]; then
        echo "TARGET_DEVICE=${MODEL}" >> "$GITHUB_ENV"
        echo "FW_ZIP_PATH=${DOWN_DIR}/${MODEL}.zip" >> "$GITHUB_ENV"
    fi

    # --- Descarga directa desde GoFile ---
    echo -e "- 📥 Downloading full firmware via aria2c..."
    aria2c -x 16 -s 16 -k 1M -d "$DOWN_DIR" -o "${MODEL}.zip" \
        --allow-overwrite=true --auto-file-renaming=false "$GOFILE_URL"
    
    if [ $? -ne 0 ]; then
        echo -e "- ⛔️ GoFile Download failed."
        return 1
    fi

    # Limpieza de archivos temporales de aria2
    wait
    find "$DOWN_DIR" -name "*.aria2" -exec rm -f {} +

    # --- Extracción Plana Directa en $FIRM_DIR ---
    echo -e "- 📦 Extracting firmware directly into absolute FIRM_DIR..."
    unzip -q "${DOWN_DIR}/${MODEL}.zip" -d "${BASE_DIR}/" 2>/dev/null || true

    # Si la extracción creó carpetas anidadas por accidente, las aplanamos al nivel de $BASE_DIR
    if [ -d "${BASE_DIR}/system/system" ]; then
        echo -e "- ⚠️ Double system directory detected! Fixing paths..."
        mv "${BASE_DIR}/system/system/"* "${BASE_DIR}/system/" 2>/dev/null || true
        rm -rf "${BASE_DIR}/system/system"
    fi

    echo -e "- ✅ Environment successfully aligned with FIRM_DIR."
}

DOWNLOAD_VENDOR() {
    if [ "$#" -lt 1 ]; then
        echo "Usage: ${FUNCNAME[0]} <DOWNLOAD_DIRECTORY>"
        return 1
    fi

    local DOWN_DIR="${1}"

    echo "Downloading vendor for ${STOCK_DEVICE}"
    aria2c -x 16 -k 1M -d "$DOWN_DIR" -o "vendor.img" --allow-overwrite=true --auto-file-renaming=false "https://github.com/JorgeSL2011/VendorsForMTKG80/releases/download/${STOCK_DEVICE}_lastest/vendor.img" &
    
    # Cleanup any leftover .aria2 control files after everything finishes
    wait
    find "$DOWN_DIR" -name "*.aria2" -exec rm -f {} +
}

EXTRACT_FIRMWARE() {
    if [ "$#" -ne 1 ]; then
        echo "Usage: ${FUNCNAME[0]} <FIRMWARE_DIRECTORY>"
        return 1
    fi

    local FIRM_DIR="$1"
    local FIRM_FILE="$FIRM_DIR/BASE_FW.zip"

    echo "Extracting downloaded firmware."

    if [ ! -f "$FIRM_FILE" ]; then
        echo "Error: BASE_FW.zip not found in $FIRM_DIR"
        return 1
    fi

    echo "- Extracting zip file."
    find "$FIRM_DIR" -maxdepth 1 -name "*.zip" \
        -exec 7z x -y -bd -o"$FIRM_DIR" {} \; >/dev/null 2>&1
    rm -rf "$FIRM_DIR"/*.zip

    rm -f "$FIRM_FILE"
}


PREPARE_PARTITIONS() {
    if [ "$#" -ne 1 ]; then
        echo "Usage: ${FUNCNAME[0]} <EXTRACTED_FIRM_DIR>"
        return 1
    fi

    local EXTRACTED_FIRM_DIR="$1"

    [[ -z "$EXTRACTED_FIRM_DIR" || ! -d "$EXTRACTED_FIRM_DIR" ]] && {
        echo "Invalid directory: $EXTRACTED_FIRM_DIR"
        return 1
    }

    IFS=',' read -r -a KEEP <<< "$BUILD_PARTITIONS"

    for i in "${!KEEP[@]}"; do
        KEEP[$i]=$(echo "${KEEP[$i]}" | xargs)
    done

    echo ""
    echo "Preparing partitions."

    shopt -s nullglob dotglob

    for item in "$EXTRACTED_FIRM_DIR"/*; do
        base=$(basename "$item")

        [[ "$base" == *.img ]] && base="${base%.img}"

        keep_this=0
        for k in "${KEEP[@]}"; do
            [[ "$k" == "$base" ]] && keep_this=1 && break
        done

        if [[ $keep_this -eq 0 ]]; then
            # echo "- Deleting: $item"
            rm -rf -- "$item"
        else
            echo "- Keeping: $item"
        fi
    done

    shopt -u nullglob dotglob
}


EXTRACT_FIRMWARE_IMG() {
    echo ""
	if [ "$#" -ne 1 ]; then
        echo "Usage: ${FUNCNAME[0]} <FIRMWARE_DIRECTORY>"
        return 1
    fi

	local FIRM_DIR="$1"

	echo "Extracting images from $FIRM_DIR"
    for imgfile in "$FIRM_DIR"/*.img; do
        [ -e "$imgfile" ] || continue

        if [[ "$(basename "$imgfile")" == "boot.img" ]]; then
            continue
        fi

        (
            local partition
            local fstype
            local IMG_SIZE

            partition="$(basename "${imgfile%.img}")"
            fstype=$(file -b $imgfile | awk '{print $1}')

            case "$fstype" in
                Linux)
                    IMG_SIZE=$(stat -c%s -- "$imgfile")
                    echo "$imgfile Detected ext4. Size: $IMG_SIZE bytes."
                    echo "Extracting $imgfile in $FIRM_DIR/$partition"
                    sudo python3 $(pwd)/bin/py_scripts/imgextractor.py "$imgfile" "$FIRM_DIR" > /dev/null 2>&1
                    ;;
                EROFS)
                    echo ""
                    IMG_SIZE=$(stat -c%s -- "$imgfile")
                    echo "$imgfile Detected $fstype. Size: $IMG_SIZE bytes."
                    echo "Extracting $imgfile in $FIRM_DIR/$partition"
                    $(pwd)/bin/erofs-utils/extract.erofs -i "$imgfile" -x -f -o "$FIRM_DIR" >/dev/null 2>&1
                    ;;
                *)
                    echo "[$imgfile] Unknown filesystem type ($fstype), skipping"
                    ;;
            esac
        ) &
    done

    wait
    # Remove all original .img
    rm -rf "$FIRM_DIR"/*.img
}
