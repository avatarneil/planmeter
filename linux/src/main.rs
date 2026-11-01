//! PlanMeter for Linux: a GTK 4 / libadwaita client of `planmeterd`.

mod ui;

fn main() -> gtk::glib::ExitCode {
    ui::main()
}
