//! Small widget helpers shared by the pages.

use adw::prelude::*;
use gtk::{gdk, glib};
use planmeter::format;

pub fn rgba(hex: &str) -> gdk::RGBA {
    let (r, g, b, a) = format::parse_hex(hex).unwrap_or((0.55, 0.56, 0.6, 1.0));
    gdk::RGBA::new(r as f32, g as f32, b as f32, a as f32)
}

/// A filled circle in a fixed color, e.g. an account's series color.
pub fn dot(hex: &str, size: i32) -> gtk::DrawingArea {
    let area = gtk::DrawingArea::builder()
        .content_width(size)
        .content_height(size)
        .valign(gtk::Align::Center)
        .halign(gtk::Align::Center)
        .accessible_role(gtk::AccessibleRole::Presentation)
        .build();
    let color = rgba(hex);
    area.set_draw_func(move |_, cr, w, h| {
        let r = f64::from(w.min(h)) / 2.0;
        cr.set_source_rgba(
            color.red().into(),
            color.green().into(),
            color.blue().into(),
            color.alpha().into(),
        );
        cr.arc(
            f64::from(w) / 2.0,
            f64::from(h) / 2.0,
            r,
            0.0,
            std::f64::consts::TAU,
        );
        let _ = cr.fill();
    });
    area
}

pub fn label(text: &str) -> gtk::Label {
    gtk::Label::builder().label(text).xalign(0.0).build()
}

pub fn label_with(text: &str, classes: &[&str]) -> gtk::Label {
    let l = label(text);
    for c in classes {
        l.add_css_class(c);
    }
    l
}

/// Dimmed caption text that wraps.
pub fn caption(text: &str) -> gtk::Label {
    let l = label_with(text, &["caption", "dim-label"]);
    l.set_wrap(true);
    l.set_wrap_mode(gtk::pango::WrapMode::WordChar);
    l
}

pub fn tag(text: &str, classes: &[&str]) -> gtk::Label {
    let l = gtk::Label::builder()
        .label(text)
        .valign(gtk::Align::Center)
        .build();
    l.add_css_class("tag");
    for c in classes {
        l.add_css_class(c);
    }
    l
}

pub fn hbox(spacing: i32) -> gtk::Box {
    gtk::Box::new(gtk::Orientation::Horizontal, spacing)
}

pub fn vbox(spacing: i32) -> gtk::Box {
    gtk::Box::new(gtk::Orientation::Vertical, spacing)
}

/// A rounded card surface, as libadwaita's boxed lists use.
pub fn card(spacing: i32) -> gtk::Box {
    let b = vbox(spacing);
    b.add_css_class("card");
    b.add_css_class("dashboard-card");
    b
}

pub fn spacer() -> gtk::Box {
    let b = hbox(0);
    b.set_hexpand(true);
    b
}

pub fn clear(container: &gtk::Box) {
    while let Some(child) = container.first_child() {
        container.remove(&child);
    }
}

/// A non-interactive boxed list.
pub fn boxed_list() -> gtk::ListBox {
    let list = gtk::ListBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .build();
    list.add_css_class("boxed-list");
    list
}

/// An action row whose title and subtitle are plain text, never markup.
pub fn row(title: &str, subtitle: &str) -> adw::ActionRow {
    adw::ActionRow::builder()
        .title(title)
        .subtitle(subtitle)
        .use_markup(false)
        .build()
}

/// A toast whose title is plain text, never markup: titles often carry device
/// names, paths, or daemon error messages.
pub fn plain_toast(text: &str) -> adw::Toast {
    adw::Toast::builder().title(text).use_markup(false).build()
}

pub fn flow(max_per_line: u32, spacing: u32) -> gtk::FlowBox {
    let f = gtk::FlowBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .homogeneous(true)
        .min_children_per_line(1)
        .max_children_per_line(max_per_line)
        .column_spacing(spacing)
        .row_spacing(spacing)
        .build();
    f.add_css_class("plain");
    f
}

/// Appends a non-focusable child so the flow box acts as pure layout.
pub fn flow_append(flow: &gtk::FlowBox, child: &impl IsA<gtk::Widget>) {
    let item = gtk::FlowBoxChild::builder()
        .child(child)
        .focusable(false)
        .build();
    flow.append(&item);
}

pub fn thin_bar(fraction: f64, class: &str) -> gtk::ProgressBar {
    let bar = gtk::ProgressBar::builder()
        .fraction(fraction.clamp(0.0, 1.0))
        .valign(gtk::Align::Center)
        .build();
    bar.add_css_class("thin");
    if !class.is_empty() {
        bar.add_css_class(class);
    }
    bar
}

/// A small flat icon button.
pub fn icon_button(icon: &str, tooltip: &str) -> gtk::Button {
    let b = gtk::Button::builder()
        .icon_name(icon)
        .tooltip_text(tooltip)
        .valign(gtk::Align::Center)
        .build();
    b.add_css_class("flat");
    b.update_property(&[gtk::accessible::Property::Label(tooltip)]);
    b
}

/// Updates a label only when the text changes (avoids needless relayouts).
pub fn set_text(label: &gtk::Label, text: &str) {
    if label.label() != text {
        label.set_label(text);
    }
}

/// Swaps one of a set of mutually exclusive CSS classes.
pub fn set_class(widget: &impl IsA<gtk::Widget>, classes: &[&str], active: &str) {
    for c in classes {
        if *c == active {
            widget.add_css_class(c);
        } else {
            widget.remove_css_class(c);
        }
    }
}

pub fn status_dot(state: &str) -> gtk::Box {
    let b = gtk::Box::builder()
        .valign(gtk::Align::Center)
        .halign(gtk::Align::Center)
        .build();
    b.add_css_class("status-dot");
    if !state.is_empty() {
        b.add_css_class(state);
    }
    b
}

pub fn markup_escape(text: &str) -> String {
    glib::markup_escape_text(text).to_string()
}
