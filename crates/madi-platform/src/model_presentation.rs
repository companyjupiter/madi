//! Native Foundation formatting and the original macOS first-run SF Symbols.
//! Draws system artwork into owned bitmaps; never captures a view or screen.
use objc2::{AnyThread, MainThreadMarker};
use objc2_app_kit::{
    NSBitmapImageFileType, NSBitmapImageRep, NSCalibratedRGBColorSpace, NSFontWeightLight,
    NSFontWeightRegular, NSFontWeightSemibold, NSGraphicsContext, NSImage,
    NSImageSymbolConfiguration,
};
use objc2_foundation::{
    NSByteCountFormatter, NSByteCountFormatterCountStyle, NSDataBase64EncodingOptions,
    NSDictionary, NSPoint, NSProcessInfo, NSRect, NSSize, NSString,
};
use serde::Serialize;
use std::collections::BTreeMap;

pub fn physical_memory() -> u64 {
    NSProcessInfo::processInfo().physicalMemory()
}

pub fn file_size(bytes: u64) -> String {
    NSByteCountFormatter::stringFromByteCount_countStyle(
        bytes.min(i64::MAX as u64) as i64,
        NSByteCountFormatterCountStyle::File,
    )
    .to_string()
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SymbolImage {
    pub data_url: String,
    pub width: f64,
    pub height: f64,
}

pub fn artwork() -> Result<BTreeMap<String, SymbolImage>, &'static str> {
    let _main =
        MainThreadMarker::new().ok_or("model artwork must be prepared on the main thread")?;
    // Exactly the names, point sizes and weights used in ModelGateView.swift.
    // Symbol pixels are generated on macOS, not redistributed as Windows assets.
    let symbols = unsafe {
        [
            ("header", "waveform", 36.0, NSFontWeightLight),
            ("required", "waveform", 18.0, NSFontWeightSemibold),
            (
                "translation",
                "character.bubble",
                18.0,
                NSFontWeightSemibold,
            ),
            ("privacy", "lock.shield", 11.0, NSFontWeightRegular),
            (
                "error",
                "exclamationmark.triangle.fill",
                11.0,
                NSFontWeightRegular,
            ),
        ]
    };
    symbols.into_iter().map(|(key, name, points, weight)| {
        let image = NSImage::imageWithSystemSymbolName_accessibilityDescription(&NSString::from_str(name), None).ok_or("system symbol unavailable")?;
        let config = NSImageSymbolConfiguration::configurationWithPointSize_weight(points, weight);
        let image = image.imageWithSymbolConfiguration(&config).ok_or("system symbol configuration unavailable")?;
        let size = image.size();
        let width = (size.width * 2.0).ceil() as isize;
        let height = (size.height * 2.0).ceil() as isize;
        // Null planes ask AppKit to allocate and own the RGBA pixel storage.
        let bitmap = unsafe { NSBitmapImageRep::initWithBitmapDataPlanes_pixelsWide_pixelsHigh_bitsPerSample_samplesPerPixel_hasAlpha_isPlanar_colorSpaceName_bytesPerRow_bitsPerPixel(
            NSBitmapImageRep::alloc(), std::ptr::null_mut(), width, height, 8, 4, true, false,
            NSCalibratedRGBColorSpace, 0, 0,
        ) }.ok_or("symbol bitmap allocation failed")?;
        let context = NSGraphicsContext::graphicsContextWithBitmapImageRep(&bitmap).ok_or("symbol bitmap context unavailable")?;
        NSGraphicsContext::saveGraphicsState_class();
        NSGraphicsContext::setCurrentContext(Some(&context));
        image.drawInRect(NSRect::new(NSPoint::new(0.0, 0.0), NSSize::new(width as f64, height as f64)));
        NSGraphicsContext::restoreGraphicsState_class();
        // The empty dictionary has no properties with mismatched value types.
        let png = unsafe { bitmap.representationUsingType_properties(NSBitmapImageFileType::PNG, &NSDictionary::new()) }.ok_or("symbol PNG encoding failed")?;
        let base64 = png.base64EncodedStringWithOptions(NSDataBase64EncodingOptions::empty());
        Ok((key.into(), SymbolImage { data_url: format!("data:image/png;base64,{base64}"), width: size.width, height: size.height }))
    }).collect()
}
