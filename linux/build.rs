fn main() {
    // Bundles the stylesheet and icons; libadwaita loads `style.css` and the
    // `icons/` folder from the application's resource base path by itself.
    glib_build_tools::compile_resources(
        &["data"],
        "data/resources.gresource.xml",
        "planmeter.gresource",
    );
}
