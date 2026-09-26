import SwiftUI
import WidgetKit

struct PlanMeterComplication: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "com.neilgoldader.planmeter.complication", intent: PlanMeterConfiguration.self, provider: PlanMeterProvider()) { entry in
            PlanMeterAccessoryView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("PlanMeter")
        .description("Choose plans and a daily spend target for your watch face.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

@main
struct PlanMeterWidgetBundle: WidgetBundle {
    var body: some Widget { PlanMeterComplication() }
}
