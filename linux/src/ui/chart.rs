//! The stacked per-account timeline, drawn with Cairo in a `GtkDrawingArea`,
//! with a hover highlight, a tooltip per bucket, and an accessible summary.

use super::widgets::rgba;
use adw::prelude::*;
use gtk::{cairo, gdk, pango};
use planmeter::chart::{nice_ticks, x_label_indices, ChartData};
use planmeter::format;
use std::cell::{Cell, RefCell};
use std::rc::Rc;

const TOP: f64 = 10.0;
const BOTTOM: f64 = 26.0;
const RIGHT: f64 = 6.0;
const GUTTER_GAP: f64 = 10.0;

struct State {
    data: Option<ChartData>,
    colors: Vec<gdk::RGBA>,
    multi_day: bool,
    clock24: bool,
    hover: Option<usize>,
    /// Plot origin and width from the last draw, for hit testing.
    plot: Cell<(f64, f64)>,
}

#[derive(Clone)]
pub struct ChartView {
    pub area: gtk::DrawingArea,
    state: Rc<RefCell<State>>,
}

impl ChartView {
    pub fn new() -> Self {
        let area = gtk::DrawingArea::builder()
            .hexpand(true)
            .content_height(230)
            .accessible_role(gtk::AccessibleRole::Img)
            .has_tooltip(true)
            .build();
        area.add_css_class("chart");
        area.update_property(&[gtk::accessible::Property::Label("Cost over time chart")]);
        let state = Rc::new(RefCell::new(State {
            data: None,
            colors: Vec::new(),
            multi_day: false,
            clock24: true,
            hover: None,
            plot: Cell::new((0.0, 0.0)),
        }));
        let view = ChartView { area, state };

        let s = view.state.clone();
        view.area.set_draw_func(move |area, cr, w, h| {
            draw(area, cr, f64::from(w), f64::from(h), &s.borrow())
        });

        let motion = gtk::EventControllerMotion::new();
        let (s, a) = (view.state.clone(), view.area.downgrade());
        motion.connect_motion(move |_, x, _| {
            let index = {
                let st = s.borrow();
                let (px, pw) = st.plot.get();
                st.data
                    .as_ref()
                    .and_then(|d| d.index_at(x, px, pw))
                    .filter(|i| st.data.as_ref().is_some_and(|d| d.bars[*i].total > 0.0))
            };
            if s.borrow().hover != index {
                s.borrow_mut().hover = index;
                if let Some(a) = a.upgrade() {
                    a.queue_draw();
                }
            }
        });
        let (s, a) = (view.state.clone(), view.area.downgrade());
        motion.connect_leave(move |_| {
            if s.borrow().hover.is_some() {
                s.borrow_mut().hover = None;
                if let Some(a) = a.upgrade() {
                    a.queue_draw();
                }
            }
        });
        view.area.add_controller(motion);

        let s = view.state.clone();
        view.area.connect_query_tooltip(move |_, x, _, _, tooltip| {
            let st = s.borrow();
            let Some(data) = st.data.as_ref() else {
                return false;
            };
            let (px, pw) = st.plot.get();
            let Some(index) = data.index_at(f64::from(x), px, pw) else {
                return false;
            };
            let bar = &data.bars[index];
            if bar.total <= 0.0 {
                return false;
            }
            let mut markup = format!(
                "<b>{}</b>",
                super::widgets::markup_escape(&format::period_span(
                    bar.start.with_timezone(&chrono::Local),
                    data.resolution,
                    st.clock24
                ))
            );
            let mut rows = bar.by_account.clone();
            rows.sort_by(|a, b| b.1.total_cmp(&a.1));
            for (account, cost) in rows {
                let name = data
                    .accounts
                    .get(account)
                    .map(|a| a.name.as_str())
                    .unwrap_or("");
                markup.push_str(&format!(
                    "\n{}  <span font_features='tnum'>{}</span>",
                    super::widgets::markup_escape(name),
                    format::usd(cost)
                ));
            }
            if bar.by_account.len() > 1 {
                markup.push_str(&format!(
                    "\n<b>Total  <span font_features='tnum'>{}</span></b>",
                    format::usd(bar.total)
                ));
            }
            if bar.tokens > 0 {
                markup.push_str(&format!(
                    "\n<span alpha='70%'>{} tokens</span>",
                    format::tokens(bar.tokens)
                ));
            }
            tooltip.set_markup(Some(&markup));
            true
        });

        let a = view.area.downgrade();
        adw::StyleManager::default().connect_dark_notify(move |_| {
            if let Some(a) = a.upgrade() {
                a.queue_draw();
            }
        });
        view
    }

    /// New data and per-account colors (hex, in `data.accounts` order).
    pub fn set_data(&self, data: ChartData, colors: Vec<String>, multi_day: bool, clock24: bool) {
        let description = data.describe(multi_day, clock24);
        {
            let mut st = self.state.borrow_mut();
            st.colors = colors.iter().map(|c| rgba(c)).collect();
            st.data = Some(data);
            st.multi_day = multi_day;
            st.clock24 = clock24;
            st.hover = None;
        }
        self.area
            .update_property(&[gtk::accessible::Property::Description(&description)]);
        self.area.queue_draw();
    }
}

fn layout(area: &gtk::DrawingArea, text: &str, scale: f64) -> pango::Layout {
    let layout = area.create_pango_layout(Some(text));
    let attrs = pango::AttrList::new();
    attrs.insert(pango::AttrFloat::new_scale(scale));
    attrs.insert(pango::AttrFontFeatures::new("tnum"));
    layout.set_attributes(Some(&attrs));
    layout
}

fn set(cr: &cairo::Context, c: &gdk::RGBA, alpha: f64) {
    cr.set_source_rgba(
        c.red().into(),
        c.green().into(),
        c.blue().into(),
        f64::from(c.alpha()) * alpha,
    );
}

fn draw(area: &gtk::DrawingArea, cr: &cairo::Context, w: f64, h: f64, st: &State) {
    let fg = area.color();
    let Some(data) = st.data.as_ref() else { return };
    if data.bars.is_empty() || data.is_empty() {
        let l = layout(area, "No usage in this range", 1.0);
        let (lw, lh) = l.pixel_size();
        set(cr, &fg, 0.55);
        cr.move_to((w - f64::from(lw)) / 2.0, (h - f64::from(lh)) / 2.0);
        pangocairo::functions::show_layout(cr, &l);
        return;
    }

    // Y axis: nice ticks and a gutter as wide as the widest label.
    let plot_h = (h - TOP - BOTTOM).max(20.0);
    let target = if plot_h > 180.0 { 4 } else { 3 };
    let (step, ticks) = nice_ticks(data.max, target);
    let top_value = *ticks.last().unwrap_or(&1.0);
    let labels: Vec<pango::Layout> = ticks
        .iter()
        .map(|v| layout(area, &format::usd_axis(*v, step), 0.82))
        .collect();
    let gutter = labels
        .iter()
        .map(|l| f64::from(l.pixel_size().0))
        .fold(0.0, f64::max)
        + GUTTER_GAP;
    let plot_x = gutter;
    let plot_w = (w - gutter - RIGHT).max(10.0);
    st.plot.set((plot_x, plot_w));
    let y_of = |v: f64| TOP + plot_h - (v / top_value) * plot_h;

    cr.set_line_width(1.0);
    for (value, label) in ticks.iter().zip(&labels) {
        let y = y_of(*value).round() + 0.5;
        set(cr, &fg, if *value == 0.0 { 0.16 } else { 0.07 });
        cr.move_to(plot_x, y);
        cr.line_to(plot_x + plot_w, y);
        let _ = cr.stroke();
        let (lw, lh) = label.pixel_size();
        set(cr, &fg, 0.55);
        cr.move_to(
            plot_x - GUTTER_GAP - f64::from(lw) + 4.0,
            y - f64::from(lh) / 2.0,
        );
        pangocairo::functions::show_layout(cr, label);
    }

    let n = data.bars.len();
    let slot = plot_w / n as f64;
    let gap = if slot >= 4.0 {
        (slot * 0.14).max(1.0)
    } else {
        0.0
    };
    // Few buckets (Today at 1 hour, early in the day) should not draw slabs.
    let bar_w = (slot - gap).clamp(0.6, 64.0);
    let inset = (slot - gap - bar_w).max(0.0) / 2.0;

    if let Some(i) = st.hover {
        set(cr, &fg, 0.06);
        cr.rectangle(plot_x + i as f64 * slot, TOP, slot, plot_h);
        let _ = cr.fill();
    }

    for (i, bar) in data.bars.iter().enumerate() {
        if bar.total <= 0.0 {
            continue;
        }
        let x = plot_x + i as f64 * slot + gap / 2.0 + inset;
        let dimmed = st.hover.is_some_and(|h| h != i);
        // Round the top of the stack only, when bars are wide enough.
        let radius = (bar_w / 4.0).min(3.0);
        cr.save().ok();
        if radius >= 1.0 {
            let top = y_of(bar.total);
            let bottom = y_of(0.0);
            rounded_top_rect(cr, x, top, bar_w, bottom - top, radius);
            cr.clip();
        }
        for seg in &bar.segments {
            let color = st.colors.get(seg.account).copied().unwrap_or(fg);
            let alpha = if seg.baseline { 0.35 } else { 1.0 } * if dimmed { 0.55 } else { 1.0 };
            set(cr, &color, alpha);
            let y0 = y_of(seg.high);
            let y1 = y_of(seg.low);
            cr.rectangle(x, y0, bar_w, (y1 - y0).max(0.5));
            let _ = cr.fill();
        }
        cr.restore().ok();
    }

    // X axis labels at round local times, skipping any that would overlap.
    let max_labels = ((plot_w / 78.0).floor() as usize).clamp(2, 10);
    let starts: Vec<_> = data.bars.iter().map(|b| b.start).collect();
    let mut last_right = f64::NEG_INFINITY;
    set(cr, &fg, 0.55);
    for i in x_label_indices(&starts, data.resolution, max_labels) {
        let text = format::period_label(
            starts[i].with_timezone(&chrono::Local),
            data.resolution,
            st.multi_day,
            st.clock24,
        );
        let l = layout(area, &text, 0.82);
        let lw = f64::from(l.pixel_size().0);
        let center = plot_x + (i as f64 + 0.5) * slot;
        let left = (center - lw / 2.0).clamp(0.0, w - lw);
        if left < last_right + 8.0 {
            continue;
        }
        cr.move_to(left, TOP + plot_h + 7.0);
        pangocairo::functions::show_layout(cr, &l);
        last_right = left + lw;
    }
}

fn rounded_top_rect(cr: &cairo::Context, x: f64, y: f64, w: f64, h: f64, r: f64) {
    let r = r.min(h / 2.0).max(0.0);
    cr.new_path();
    cr.move_to(x, y + h);
    cr.line_to(x, y + r);
    cr.arc(
        x + r,
        y + r,
        r,
        std::f64::consts::PI,
        1.5 * std::f64::consts::PI,
    );
    cr.line_to(x + w - r, y);
    cr.arc(x + w - r, y + r, r, 1.5 * std::f64::consts::PI, 0.0);
    cr.line_to(x + w, y + h);
    cr.close_path();
}
