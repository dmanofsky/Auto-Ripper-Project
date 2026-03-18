#!/bin/bash
# ==============================================================================
# SCRIPT: TRaSH File Masher
# VERSION: 1.2.2
# PURPOSE: Recursively scans multiple media directories (movies & shows), 
#          corrects TMDB ID brackets for Jellyfin, uses ffprobe to determine 
#          true resolution/HDR, and standardizes the filename.
# ==============================================================================

# --- Configuration ---
TARGET_DIRS=("/mnt/tank/media/movies" "/mnt/tank/media/shows") # <--- Verify your TrueNAS paths!
DRY_RUN=true                                                   # <--- Set to 'false' to actually rename the files

echo "========================================="
echo "       STARTING TRaSH FILE MASHER        "
echo "========================================="
if [ "$DRY_RUN" = true ]; then
    echo "⚠️  DRY RUN MODE ENABLED: No files will be changed."
else
    echo "🔥 LIVE MODE ENABLED: Files will be renamed."
fi
echo "========================================="

for TARGET_DIR in "${TARGET_DIRS[@]}"; do
    
    if [ ! -d "$TARGET_DIR" ]; then
        echo "[WARNING] Directory not found, skipping: $TARGET_DIR"
        continue
    fi

    echo "Scanning Directory: $TARGET_DIR"

    # Find all MKV and MP4 files recursively
    find "$TARGET_DIR" -type f \( -iname "*.mkv" -o -iname "*.mp4" \) | while read -r filepath; do
        
        dir=$(dirname "$filepath")
        filename=$(basename "$filepath")
        extension="${filename##*.}"
        base_name="${filename%.*}"

        # ==========================================================================
        # PHASE 1: THE CLEANUP
        # ==========================================================================
        clean_name=$(echo "$base_name" | perl -pe 's/[\{\[]tmdb(id)?-(\d+)[\}\]]/\[tmdbid-$2\]/ig')
        clean_name=$(echo "$clean_name" | perl -pe 's/(?i)\b(2160p|1080p|720p|480p|HDR|SDR|Remux)\b//g')
        clean_name=$(echo "$clean_name" | perl -pe 's/\s+-\s+-/\s-\s/g') 
        clean_name=$(echo "$clean_name" | perl -pe 's/^\s*-\s*//')       
        clean_name=$(echo "$clean_name" | perl -pe 's/\s*-\s*$//')       
        clean_name=$(echo "$clean_name" | perl -pe 's/\s+/ /g')          
        clean_name=$(echo "$clean_name" | perl -pe 's/\s+$//')           

        # ==========================================================================
        # PHASE 2: THE X-RAY
        # ==========================================================================
        width=$(./ffprobe -v error -select_streams v:0 -show_entries stream=width -of default=noprint_wrappers=1:nokey=1 "$filepath" | head -n 1 | tr -cd '0-9')
        height=$(./ffprobe -v error -select_streams v:0 -show_entries stream=height -of default=noprint_wrappers=1:nokey=1 "$filepath" | head -n 1 | tr -cd '0-9')
        transfer=$(./ffprobe -v error -select_streams v:0 -show_entries stream=color_transfer -of default=noprint_wrappers=1:nokey=1 "$filepath" | head -n 1 | tr -d '\r')

        if [ -z "$width" ] || [ -z "$height" ]; then
            echo "[ERROR] Could not probe: $filename"
            continue
        fi

        # ==========================================================================
        # PHASE 3: THE CALCULATION
        # ==========================================================================
        res="Unknown"
        
        # --- BUG FIX: Fully expanded if/elif block to prevent token errors ---
        if [ "$width" -ge 3200 ] || [ "$height" -ge 2100 ]; then 
            res="2160p"
        elif [ "$width" -ge 1900 ] || [ "$height" -ge 1000 ]; then 
            res="1080p"
        elif [ "$width" -ge 1200 ] || [ "$height" -ge 700 ]; then 
            res="720p"
        else 
            res="480p"
        fi

        hdr_tag=""
        if [[ "$transfer" == "smpte2084" ]] || [[ "$transfer" == "arib-std-b67" ]]; then
            hdr_tag=" HDR"
        fi

        # ==========================================================================
        # PHASE 4: THE RE-ASSEMBLY
        # ==========================================================================
        new_name="${clean_name} - ${res} Remux${hdr_tag}.${extension}"

        if [ "$filename" == "$new_name" ]; then continue; fi

        echo "📄 Original: $filename"
        echo "✨ Upgraded: $new_name"
        echo "-------------------------------------------------"

        if [ "$DRY_RUN" = false ]; then
            mv "$filepath" "$dir/$new_name"
        fi

    done
done

echo "Done Mashing Files!"