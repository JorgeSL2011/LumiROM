#!/bin/bash

DOWNLOAD_FIRMWARE() {
    if [ "$#" -lt 2 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <DOWNLOAD_DIRECTORY> <GOFILE_DIRECT_URL>"
        return 1
    fi

    local DOWN_DIR="$1"
    local GOFILE_URL="$2"
    
    # Extracción automática del modelo basado en el archivo de la URL
    local FILE_NAME="${GOFILE_URL##*/}"
    FILE_NAME="${FILE_NAME%%\?*}"
    local MODEL="${FILE_NAME%.zip}"
    DOWN_DIR="${DOWN_DIR}/$MODEL"

    rm -rf "$DOWN_DIR"
    mkdir -p "$DOWN_DIR"

    echo -e "======================================"
    echo -e "   GitHub Actions FW Downloader (GoFile) "
    echo -e "======================================"
    echo -e "DETECTED MODEL: $MODEL"

    # --- Exportar variables críticas para los siguientes steps de GitHub Actions ---
    export TARGET_DEVICE="$MODEL"
    if [ -n "$GITHUB_ENV" ]; then
        echo "TARGET_DEVICE=$MODEL" >> "$GITHUB_ENV"
        echo "FW_ZIP_PATH=${DOWN_DIR}/${FILE_NAME}" >> "$GITHUB_ENV"
    fi

    # --- Descarga directa desde GoFile ---
    echo -e "- 📥 Downloading full firmware via aria2c..."
    aria2c -x 16 -s 16 -k 1M -d "$DOWN_DIR" -o "$FILE_NAME" \
        --allow-overwrite=true --auto-file-renaming=false "$GOFILE_URL"
    
    if [ $? -ne 0 ]; then
        echo -e "- ⛔️ GoFile Download failed. Check if the link has expired."
        return 1
    fi

    # --- Limpieza de archivos de control de aria2 ---
    wait
    find "$DOWN_DIR" -name "*.aria2" -exec rm -f {} +

    # --- Verificación final de la descarga ---
    if [ -f "${DOWN_DIR}/${FILE_NAME}" ]; then
        local file_size=$(du -m "${DOWN_DIR}/${FILE_NAME}" | cut -f1)
        echo -e "- ✅ Firmware downloaded and ready! Size: ${file_size} MB"
        echo -e "- Saved to: ${DOWN_DIR}/${FILE_NAME}"
    else
        echo -e "- ⛔️ Firmware file was not found."
        return 1
    fi
}

DOWNLOAD_VENDOR() {
    if [ "$#" -lt 1 ]; then
        echo "Usage: ${FUNCNAME[0]} <DOWNLOAD_DIRECTORY>"
        return 1
    fi

    local DOWN_DIR="${1}"

    echo "Downloading vendor for ${STOCK_DEVICE}"
    aria2c -x 16 -k 1M -d "$DOWN_DIR" -o "vendor.img" --allow-overwrite=true --auto-file-renaming=false "https://github.com/Luminous418/VendorsForMTKG80/releases/download/${STOCK_DEVICE}_latest/vendor.img" &
    
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
