package com.neilgoldader.planmeter.mobile.ui.theme

import androidx.compose.material3.Typography
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

val PlanMeterTypography = Typography()

/** Tabular figures so amounts line up and don't jitter while refreshing. */
fun TextStyle.tabular(): TextStyle = copy(fontFeatureSettings = "tnum")

val HeroNumberStyle = TextStyle(fontSize = 40.sp, lineHeight = 46.sp, fontWeight = FontWeight.SemiBold, fontFeatureSettings = "tnum")
val CardNumberStyle = TextStyle(fontSize = 28.sp, lineHeight = 34.sp, fontWeight = FontWeight.SemiBold, fontFeatureSettings = "tnum")
