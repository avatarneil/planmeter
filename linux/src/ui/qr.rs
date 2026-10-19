//! A crisp QR code drawn module by module with Cairo, on a white card so
//! phone cameras read it in dark mode too.

use adw::prelude::*;
use qrcode::{Color, EcLevel, QrCode};

pub fn qr_widget(payload: &str, size: i32, description: &str) -> gtk::Widget {
    let Ok(code) = QrCode::with_error_correction_level(payload.as_bytes(), EcLevel::M) else {
        let l = gtk::Label::new(Some("This pairing link is too long for a QR code."));
        l.add_css_class("dim-label");
        l.set_wrap(true);
        return l.upcast();
    };
    let width = code.width();
    let dark: Vec<bool> = code
        .to_colors()
        .into_iter()
        .map(|c| c == Color::Dark)
        .collect();
    let area = gtk::DrawingArea::builder()
        .content_width(size)
        .content_height(size)
        .halign(gtk::Align::Center)
        .accessible_role(gtk::AccessibleRole::Img)
        .build();
    area.update_property(&[gtk::accessible::Property::Label(description)]);
    area.set_draw_func(move |_, cr, w, h| {
        let side = f64::from(w.min(h));
        // Whole-pixel modules keep edges sharp; the frame supplies the quiet zone.
        let module = (side / width as f64).floor().max(1.0);
        let offset_x = ((f64::from(w) - module * width as f64) / 2.0).floor();
        let offset_y = ((f64::from(h) - module * width as f64) / 2.0).floor();
        cr.set_source_rgb(0.0, 0.0, 0.0);
        for (i, is_dark) in dark.iter().enumerate() {
            if *is_dark {
                let (x, y) = ((i % width) as f64, (i / width) as f64);
                cr.rectangle(offset_x + x * module, offset_y + y * module, module, module);
            }
        }
        let _ = cr.fill();
    });
    let frame = gtk::Box::builder().halign(gtk::Align::Center).build();
    frame.add_css_class("qr-frame");
    frame.append(&area);
    frame.upcast()
}
