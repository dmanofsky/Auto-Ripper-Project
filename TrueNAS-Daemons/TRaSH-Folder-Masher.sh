#!/bin/bash
# ==============================================================================
# SCRIPT: TRaSH Folder Masher
# VERSION: 1.1.2
# PURPOSE: Depth-first scan of movies and shows. Standardizes TMDB brackets 
#          to [tmdbid-1234] and zero-pads TV season folders (e.g., Season 01).
# ==============================================================================

# --- Configuration ---
TARGET_DIRS=("/mnt/tank/media/movies" "/mnt/tank/media/shows") # <--- Verify your TrueNAS paths!
DRY_RUN=true                                                   # <--- Set to 'false' to actually rename the folders

echo "========================================="
echo "       STARTING TRaSH FOLDER MASHER      "
echo "========================================="
if [ "$DRY_RUN" = true ]; then
    echo "⚠️  DRY RUN MODE ENABLED: No directories will be changed."
else
    echo "🔥 LIVE MODE ENABLED: Directories will be renamed."
fi
echo "========================================="

for TARGET_DIR in "${TARGET_DIRS[@]}"; do
    
    if [ ! -d "$TARGET_DIR" ]; then
        echo "[WARNING] Directory not found, skipping: $TARGET_DIR"
        continue
    fi

    echo "Scanning Directory: $TARGET_DIR"

    # We MUST use -depth to process child folders BEFORE parent folders.
    find "$TARGET_DIR" -depth -type d | while read -r dirpath; do
        
        parent_dir=$(dirname "$dirpath")
        dirname=$(basename "$dirpath")
        
        # ==========================================================================
        # THE CLEANUP
        # ==========================================================================
        clean_dirname=$(echo "$dirname" | perl -pe 's/[\{\[]tmdb(id)?-(\d+)[\}\]]/\[tmdbid-$2\]/ig')
        clean_dirname=$(echo "$clean_dirname" | perl -pe 's/^Season\s+(\d)$/Season 0$1/ig')
        
        if [ "$dirname" == "$clean_dirname" ]; then continue; fi

        echo "📁 Original: $dirname"
        echo "✨ Upgraded: $clean_dirname"
        echo "-------------------------------------------------"

        if [ "$DRY_RUN" = false ]; then
            mv "$dirpath" "$parent_dir/$clean_dirname"
        fi

    done
done

echo "Done Mashing Folders!"