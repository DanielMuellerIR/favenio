"""Erzeugt die Swift-Konstanten aus den Lesebudgets des Suchkerns."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import favenio  # noqa: E402


LIMITS = {
    "documentBytes": favenio.DOCUMENT_BYTES,
    "documentPageBytes": favenio.DOCUMENT_PAGE_BYTES,
    "documentPages": favenio.DOCUMENT_PAGES,
    "pdfOCRPages": favenio.PDF_OCR_PAGES,
    "pdfOCRRenderedPages": favenio.PDF_OCR_RENDERED_PAGES,
    "pdfOCRDPI": favenio.PDF_OCR_DPI,
    "pdfOCRRenderPixels": favenio.PDF_OCR_RENDER_PIXELS,
    "pdfOCRTotalRenderPixels": favenio.PDF_OCR_TOTAL_RENDER_PIXELS,
    "pdfOCRRenderEdge": favenio.PDF_OCR_RENDER_EDGE,
    "ocrPixels": favenio.OCR_PIXELS,
    "ocrEdge": favenio.OCR_EDGE,
    "ocrBlocks": favenio.OCR_BLOCKS,
    "ocrTextBytes": favenio.OCR_TEXT_BYTES,
    "ocrBlockBytes": favenio.OCR_BLOCK_BYTES,
    "ocrMinimumConfidence": favenio.OCR_MINIMUM_CONFIDENCE,
    "visionMinimumTextHeight": favenio.VISION_MINIMUM_TEXT_HEIGHT,
    "visionMaximumBitDepth": favenio.VISION_MAXIMUM_BIT_DEPTH,
}


if __name__ == "__main__":
    statements = "\n".join(f"    static let {name} = {value}" for name, value in LIMITS.items())
    Path(sys.argv[1]).write_text(f"enum DocumentHelperLimits {{\n{statements}\n}}\n", encoding="utf-8")
