import SwiftUI
import WidgetKit

struct PlanMeterComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.neilgoldader.planmeter.complication", provider: PlanMeterProvider()) { entry in
            PlanMeterAccessoryView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("PlanMeter")
        .description("Today's AI spend, personal vs work, and Codex limits.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

@main
struct PlanMeterWidgetBundle: WidgetBundle {
    var body: some Widget { PlanMeterComplication() }
}
