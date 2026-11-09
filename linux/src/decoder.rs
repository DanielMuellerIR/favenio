use super::*;
pub(super) fn run(arguments: &[std::ffi::OsString]) -> Result<(), String> {
    let ocr = arguments[1] == "--normalize-ocr";
    if arguments.len() != 5 {
        return Err("Ungültiger Decoderauftrag.".into());
    }
    let source = PathBuf::from(&arguments[2]);
    let target = PathBuf::from(&arguments[3]);
    let (_, width, height) = gtk::gdk_pixbuf::Pixbuf::file_info(&source).ok_or("ocrDamaged")?;
    if width <= 0
        || height <= 0
        || width > if ocr { 8192 } else { 32768 }
        || height > if ocr { 8192 } else { 32768 }
        || (ocr && i64::from(width) * i64::from(height) > 12_000_000)
    {
        return Err("ocrLimit".into());
    }
    let pixbuf = if ocr {
        let animation =
            gtk::gdk_pixbuf::PixbufAnimation::from_file(&source).map_err(|_| "ocrDamaged")?;
        if !animation.is_static_image() {
            return Err("ocrMultipleFrames".into());
        }
        animation.static_image().ok_or("ocrDamaged")?
    } else {
        let edge = arguments[4]
            .to_str()
            .and_then(|s| s.parse::<i32>().ok())
            .filter(|&n| (64..=1800).contains(&n))
            .ok_or("Ungültige Vorschaugröße")?;
        gtk::gdk_pixbuf::Pixbuf::from_file_at_scale(&source, edge, edge, true)
            .map_err(|e| e.to_string())?
    };
    let oriented = pixbuf.apply_embedded_orientation().ok_or("ocrDamaged")?;
    oriented
        .savev(target, "png", &[])
        .map_err(|e| e.to_string())
}
