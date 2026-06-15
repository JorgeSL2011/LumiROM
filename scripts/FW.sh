#!/bin/bash

DOWNLOAD_FIRMWARE() {
    if [ "$#" -lt 2 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <DOWNLOAD_DIRECTORY> <GOFILE_DIRECT_URL>"
        return 1
    fi

    local BASE_DIR="$1"
    local HF_URL="$2"

    local MODEL="$STOCK_DEVICE"
    local DOWN_DIR="${BASE_DIR}/${MODEL}"

    rm -rf "$DOWN_DIR"
    mkdir -p "$DOWN_DIR"

    echo -e "========================================"
    echo -e "   GitHub Actions FW Downloader (GoFile) "
    echo -e "========================================"
    echo -e "FIRM_DIR: $BASE_DIR"
    echo -e "TARGET MODEL: $MODEL"
    echo -e "FILE SOURCE: Direct super.img Link"

    # Exportar variables globales para los siguientes pasos del workflow
    export TARGET_DEVICE="$MODEL"
    if [ -n "$GITHUB_ENV" ]; then
        echo "TARGET_DEVICE=${MODEL}" >> "$GITHUB_ENV"
        echo "FW_ZIP_PATH=${DOWN_DIR}/super.img" >> "$GITHUB_ENV"
    fi

    # --- Descarga directa desde GoFile ---
    echo -e "- 📥 Downloading super.img via curl..."
    # Forzamos el nombre de salida a super.img sin importar los IDs de la URL
    # Cambiar el aria2c por esto en tu DOWNLOAD_FIRMWARE:
	curl -L "$HF_URL" -o "$DOWN_DIR/super.img"

    if [ $? -ne 0 ]; then
        echo -e "- ⛔️ GoFile Download failed. Verify if the direct token expired."
        return 1
    fi

    # Limpieza de archivos de control de aria2
    wait
    find "$DOWN_DIR" -name "*.aria2" -exec rm -f {} +
    echo -e "- ✅ Download completed successfully."
}


DOWNLOAD_VENDOR() {
    if [ "$#" -lt 1 ]; then
        echo "Usage: ${FUNCNAME[0]} <DOWNLOAD_DIRECTORY>"
        return 1
    fi

    local DOWN_DIR="${1}"
    mkdir -p "$DOWN_DIR"

    echo "Downloading vendor for ${STOCK_DEVICE}..."
    aria2c -x 16 -s 16 -k 1M -d "$DOWN_DIR" -o "vendor.img" \
        --allow-overwrite=true --auto-file-renaming=false "https://github.com/JorgeSL2011/VendorsForMTKG80/releases/download/${STOCK_DEVICE}_lastest/vendor.img"

    wait
    find "$DOWN_DIR" -name "*.aria2" -exec rm -f {} +
    echo "- ✅ Vendor downloaded."
}


EXTRACT_FIRMWARE() {
    if [ "$#" -ne 1 ]; then
        echo "Usage: ${FUNCNAME[0]} <FIRMWARE_DIRECTORY>"
        return 1
    fi

    local FIRM_DIR="$1"
    local MODEL="$STOCK_DEVICE"
    local SUPER_FILE="$FIRM_DIR/$MODEL/super.img"

    echo "========================================"
    echo "   Extracting Dynamic Partitions (LP)   "
    echo "========================================"

    if [ ! -f "$SUPER_FILE" ]; then
        echo "⛔️ Error: super.img not found in $FIRM_DIR/$MODEL/"
        return 1
    fi

    # Instalar herramientas de desempaquetado de Android en el runner si faltan
    if ! command -v lpunpack &> /dev/null; then
        echo "- 🔧 Installing android-sdk-libresim (simg2img/lpunpack)..."
        sudo apt-get update && sudo apt-get install -y android-sdk-libresim simg2img || true
    fi

    # Convertir de Android Sparse a Raw Image por seguridad (exigido por lpunpack)
    if simg2img "$SUPER_FILE" "$FIRM_DIR/$MODEL/super.raw.img" 2>/dev/null; then
        echo "- ✅ Converted sparse super.img to raw."
        local READY_SUPER="$FIRM_DIR/$MODEL/super.raw.img"
    else
        echo "- ℹ️ super.img is already a raw image."
        local READY_SUPER="$SUPER_FILE"
    fi

    # Crear los directorios destino planos que el config del script espera encontrar
    mkdir -p "$FIRM_DIR/system" "$FIRM_DIR/vendor" "$FIRM_DIR/product" "$FIRM_DIR/system_ext" "$FIRM_DIR/odm"

    # Desempaquetar el super usando lpunpack directamente en la raíz de FIRMWARE
    echo "- 🔓 Unpacking partitions via lpunpack..."
    lpunpack "$READY_SUPER" "$FIRM_DIR/"

    # Limpieza inmediata de imágenes pesadas para no saturar el almacenamiento de Actions
    rm -f "$FIRM_DIR/$MODEL/super.raw.img" 2>/dev/null || true
    rm -rf "$FIRM_DIR/$MODEL"

    echo "- ✅ Extraction complete. Individual partition images generated in FIRM_DIR."
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
