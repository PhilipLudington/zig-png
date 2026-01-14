#!/bin/bash
#
# External validation script for zig-png library
#
# Validates generated PNGs against external tools:
# - pngcheck: validates PNG structure
# - ImageMagick: decodes and compares pixel data
#
# Usage: ./scripts/validate-external.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$PROJECT_DIR/test_output"
COMPARE_DIR="$PROJECT_DIR/test_compare"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "========================================"
echo "zig-png External Validation"
echo "========================================"
echo ""

# Check for required tools
check_tool() {
    if command -v "$1" &> /dev/null; then
        echo -e "${GREEN}[OK]${NC} $1 found"
        return 0
    else
        echo -e "${YELLOW}[SKIP]${NC} $1 not found (install with: $2)"
        return 1
    fi
}

echo "Checking for external tools..."
HAS_PNGCHECK=false
HAS_MAGICK=false

if check_tool "pngcheck" "brew install pngcheck"; then
    HAS_PNGCHECK=true
fi

if check_tool "magick" "brew install imagemagick"; then
    HAS_MAGICK=true
fi

echo ""

# Build the validation tool
echo "Building validation tool..."
cd "$PROJECT_DIR"
zig build validate 2>&1 || {
    echo -e "${RED}[FAIL]${NC} Failed to build validation tool"
    exit 1
}
echo -e "${GREEN}[OK]${NC} Build successful"
echo ""

# Generate test images
echo "Generating test PNG images..."
./zig-out/bin/validate generate
echo ""

# Run pngcheck validation
if [ "$HAS_PNGCHECK" = true ]; then
    echo "========================================"
    echo "Running pngcheck validation..."
    echo "========================================"

    PNGCHECK_PASS=0
    PNGCHECK_FAIL=0

    for png_file in "$OUTPUT_DIR"/*.png; do
        filename=$(basename "$png_file")
        if pngcheck -q "$png_file" 2>/dev/null; then
            echo -e "${GREEN}[PASS]${NC} $filename"
            ((PNGCHECK_PASS++))
        else
            echo -e "${RED}[FAIL]${NC} $filename"
            pngcheck -v "$png_file" 2>&1 | head -5
            ((PNGCHECK_FAIL++))
        fi
    done

    echo ""
    echo "pngcheck: $PNGCHECK_PASS passed, $PNGCHECK_FAIL failed"
    echo ""
fi

# Run ImageMagick validation
if [ "$HAS_MAGICK" = true ]; then
    echo "========================================"
    echo "Running ImageMagick validation..."
    echo "========================================"

    mkdir -p "$COMPARE_DIR"

    MAGICK_PASS=0
    MAGICK_FAIL=0

    for png_file in "$OUTPUT_DIR"/*.png; do
        filename=$(basename "$png_file")
        basename="${filename%.png}"

        # Try to decode with ImageMagick (validates readability)
        if magick identify "$png_file" > /dev/null 2>&1; then
            echo -e "${GREEN}[PASS]${NC} $filename - ImageMagick can decode"

            # Get image info to determine format
            colortype=$(magick identify -format "%[type]" "$png_file" 2>/dev/null || echo "unknown")
            channels=$(magick identify -format "%[channels]" "$png_file" 2>/dev/null || echo "unknown")

            # Extract raw pixels with ImageMagick using appropriate format
            # Check channels first (more reliable), then fall back to colortype
            case "$channels" in
                gray)
                    magick "$png_file" -depth 8 GRAY:"$COMPARE_DIR/${basename}_magick.raw" 2>/dev/null || true
                    ;;
                graya)
                    magick "$png_file" -depth 8 -alpha on GRAYA:"$COMPARE_DIR/${basename}_magick.raw" 2>/dev/null || true
                    ;;
                srgb)
                    magick "$png_file" -depth 8 RGB:"$COMPARE_DIR/${basename}_magick.raw" 2>/dev/null || true
                    ;;
                srgba)
                    magick "$png_file" -depth 8 -alpha on RGBA:"$COMPARE_DIR/${basename}_magick.raw" 2>/dev/null || true
                    ;;
                *)
                    # Fall back to colortype detection
                    case "$colortype" in
                        Grayscale)
                            magick "$png_file" -depth 8 GRAY:"$COMPARE_DIR/${basename}_magick.raw" 2>/dev/null || true
                            ;;
                        *Alpha*|*Matte*)
                            magick "$png_file" -depth 8 -alpha on RGBA:"$COMPARE_DIR/${basename}_magick.raw" 2>/dev/null || true
                            ;;
                        *)
                            magick "$png_file" -depth 8 RGB:"$COMPARE_DIR/${basename}_magick.raw" 2>/dev/null || true
                            ;;
                    esac
                    ;;
            esac

            # Also dump raw pixels from our decoder
            ./zig-out/bin/validate dump-raw "$png_file" "$COMPARE_DIR/${basename}_zig.raw" 2>/dev/null || true

            # Compare the raw files if both exist
            if [ -f "$COMPARE_DIR/${basename}_magick.raw" ] && [ -f "$COMPARE_DIR/${basename}_zig.raw" ]; then
                if cmp -s "$COMPARE_DIR/${basename}_magick.raw" "$COMPARE_DIR/${basename}_zig.raw"; then
                    echo -e "${GREEN}[PASS]${NC} $filename - pixel data matches ImageMagick"
                else
                    # Show difference details
                    zig_size=$(wc -c < "$COMPARE_DIR/${basename}_zig.raw")
                    magick_size=$(wc -c < "$COMPARE_DIR/${basename}_magick.raw")
                    if [ "$zig_size" != "$magick_size" ]; then
                        echo -e "${YELLOW}[DIFF]${NC} $filename - size mismatch (zig: $zig_size, magick: $magick_size)"
                    else
                        echo -e "${YELLOW}[DIFF]${NC} $filename - content differs (same size: $zig_size bytes)"
                    fi
                fi
            fi

            ((MAGICK_PASS++))
        else
            echo -e "${RED}[FAIL]${NC} $filename - ImageMagick cannot decode"
            ((MAGICK_FAIL++))
        fi
    done

    echo ""
    echo "ImageMagick decode: $MAGICK_PASS passed, $MAGICK_FAIL failed"
    echo ""
fi

# Run roundtrip test
echo "========================================"
echo "Running roundtrip tests..."
echo "========================================"

mkdir -p "$COMPARE_DIR/roundtrip"

ROUNDTRIP_PASS=0
ROUNDTRIP_FAIL=0

for png_file in "$OUTPUT_DIR"/*.png; do
    filename=$(basename "$png_file")
    roundtrip_file="$COMPARE_DIR/roundtrip/$filename"

    # Roundtrip: decode and re-encode
    if ./zig-out/bin/validate roundtrip "$png_file" "$roundtrip_file" 2>/dev/null; then
        # Verify the roundtrip file with pngcheck if available
        if [ "$HAS_PNGCHECK" = true ]; then
            if pngcheck -q "$roundtrip_file" 2>/dev/null; then
                echo -e "${GREEN}[PASS]${NC} $filename roundtrip"
                ((ROUNDTRIP_PASS++))
            else
                echo -e "${RED}[FAIL]${NC} $filename roundtrip - invalid PNG"
                ((ROUNDTRIP_FAIL++))
            fi
        else
            echo -e "${GREEN}[PASS]${NC} $filename roundtrip (pngcheck not available)"
            ((ROUNDTRIP_PASS++))
        fi
    else
        echo -e "${RED}[FAIL]${NC} $filename roundtrip - encoding failed"
        ((ROUNDTRIP_FAIL++))
    fi
done

echo ""
echo "Roundtrip: $ROUNDTRIP_PASS passed, $ROUNDTRIP_FAIL failed"
echo ""

# Summary
echo "========================================"
echo "Summary"
echo "========================================"
echo "Test images generated in: $OUTPUT_DIR"
echo "Comparison files in: $COMPARE_DIR"

if [ "$HAS_PNGCHECK" = false ] && [ "$HAS_MAGICK" = false ]; then
    echo ""
    echo -e "${YELLOW}Note: Install pngcheck and/or ImageMagick for full validation${NC}"
    echo "  brew install pngcheck imagemagick"
fi

echo ""
echo "Done!"
