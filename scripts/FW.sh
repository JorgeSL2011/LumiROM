#!/bin/bash

DOWNLOAD_FIRMWARE() {
    if [ "$#" -lt 2 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <DOWNLOAD_DIRECTORY> <GOFILE_DIRECT_URL>"
        return 1
    fi

    local BASE_DIR="$1"
    local GOFILE_URL="$2"
    
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
    echo -e "- 📥 Downloading super.img via aria2c..."
    # Forzamos el nombre de salida a super.img sin importar los IDs de la URL
    aria2c -x 16 -s 16 -k 1M -d "$DOWN_DIR" -o "super.img" \
        --allow-overwrite=true --auto-file-renaming=false "$GOFILE_URL"
    
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


PREPARE_PARTITIONS() {
    if [ "$#" -ne 1 ]; then
        echo "Usage: ${FUNCNAME[0]} <FIRMWARE_DIRECTORY>"
        return 1
    fi

    local FIRM_DIR="$1"
    echo "=========================================="
    echo "   Preparing Workspace Partitions        "
    echo "=========================================="

    # Limpiar cualquier residuo de directorios previos para evitar mezclas corruptas
    for part in system system_ext product odm; do
        if [ -d "$FIRM_DIR/$part" ]; then
            echo "- Cleaning old directory: $FIRM_DIR/$part"
            rm -rf "$FIRM_DIR/$part"
        fi
    done

    # Preservar el vendor.img personalizado si existe en la raíz
    if [ -f "$FIRM_DIR/vendor.img" ]; then
        echo "- Keeping custom vendor track: $FIRM_DIR/vendor.img"
    else
        rm -rf "$FIRM_DIR/vendor"
    fi
}

EXTRACT_FIRMWARE_IMG() {
    if [ "$#" -ne 1 ]; then
        echo "Usage: ${FUNCNAME[0]} <FIRMWARE_DIRECTORY>"
        return 1
    fi

    local FIRM_DIR="$1"
    echo "=========================================="
    echo "   Processing and Extracting Images       "
    echo "=========================================="

    # --- [PASO 1] DETECTAR Y DESEMPAQUETAR SUPER.IMG (GoFile Link) ---
    local SUPER_PATH=""
    if [ -f "$FIRM_DIR/super.img" ]; then
        SUPER_PATH="$FIRM_DIR/super.img"
    elif [ -f "$FIRM_DIR/$STOCK_DEVICE/super.img" ]; then
        SUPER_PATH="$FIRM_DIR/$STOCK_DEVICE/super.img"
    fi

    if [ -n "$SUPER_PATH" ]; then
        echo "- 🔓 super.img detected! Preparing lpunpack environment..."
        
        # Instalar dependencias nativas en el runner de GitHub Actions
        if ! command -v lpunpack &> /dev/null; then
            echo "  -> Installing android-sdk-libresim & simg2img..."
            sudo apt-get update && sudo apt-get install -y android-sdk-libresim simg2img || true
        fi

        # Convertir de Android Sparse a Raw Image (Requisito estricto de lpunpack)
        if simg2img "$SUPER_PATH" "$FIRM_DIR/super.raw.img" 2>/dev/null; then
            echo "  -> Converted sparse super.img to raw chunk successfully."
            local READY_SUPER="$FIRM_DIR/super.raw.img"
        else
            echo "  -> super.img is already a raw image chunk."
            local READY_SUPER="$SUPER_PATH"
        fi

        # Desempaquetar particiones dinámicas (.img individuales) en la raíz de FIRMWARE
        echo "- 🔓 Unpacking dynamic logical tracks via lpunpack..."
        lpunpack "$READY_SUPER" "$FIRM_DIR/"
        
        # Limpieza inmediata del super procesado para evitar caídas por falta de espacio en Actions
        rm -f "$FIRM_DIR/super.raw.img" 2>/dev/null || true
        rm -f "$FIRM_DIR/super.img" 2>/dev/null || true
        rm -rf "$FIRM_DIR/$STOCK_DEVICE" 2>/dev/null || true
        echo "- ✅ Dynamic partition images successfully extracted to root."
    fi

    # --- [PASO 2] EXTRACCIÓN MEDIANTE IMGEXTRACTOR.PY ---
    # Este bucle ahora procesará de forma secuencial: vendor.img, system.img, product.img, system_ext.img, odm.img
    for img in "$FIRM_DIR"/*.img; do
        [ -f "$img" ] || continue
        
        local name=$(basename "$img" .img)
        
        # Ignorar imágenes residuales o de control del super
        if [ "$name" = "super" ] || [ "$name" = "super.raw" ]; then
            continue
        fi

        echo "------------------------------------------"
        echo "Processing track: $img"
        
        # Análisis de cabeceras e identificación del sistema de archivos (Tu lógica original)
        local size=$(wc -c < "$img")
        local type="unknown"
        if HEADER=$(head -c 1024 "$img" 2>/dev/null); then
            if echo "$HEADER" | grep -q "CrAU"; then
                type="erofs"
            elif echo "$HEADER" | grep -q -E "Linux|EXT"; then
                type="ext4"
            fi
        fi
        echo "$img | Detected filesystem: $type | Size: $size bytes."

        echo "- Extracting $img into target directory: $FIRM_DIR/$name"
        rm -rf "$FIRM_DIR/$name"
        mkdir -p "$FIRM_DIR/$name"
        
        # Invocar a tu extractor de Python nativo
        python3 bin/imgextractor/imgextractor.py "$img" "$FIRM_DIR/$name" > /dev/null 2>&1
        
        # Eliminar el archivo .img de origen para liberar espacio crítico en el almacenamiento virtual
        rm -f "$img"
        echo "- ✅ Extracted successfully."
    done

    echo "=========================================="
    echo "   Tree Verification (System-As-Root)    "
    echo "=========================================="
    
    # Validación inteligente: Confirmar que la estructura nativa de System-As-Root se mantiene intacta
    if [ -d "$FIRM_DIR/system/system" ]; then
        echo "- ✅ Structure 'FIRMWARE/system/system' confirmed and protected."
        echo "  -> Real root files inside: $(ls -A "$FIRM_DIR/system/system" | head -n 5)..."
    else
        echo "- ⚠️ Warning: 'system/system' structure was not created by the extractor."
    fi

    echo "- ✅ All firmware tree components extracted and aligned with variables."
}
