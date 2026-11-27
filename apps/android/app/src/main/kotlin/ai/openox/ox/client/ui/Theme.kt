package ai.openox.ox.client.ui

import ai.openox.ox.client.features.settings.Appearance
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

@Immutable
data class OxColors(
    val conversationSurface: Color,
    val bubble: Color,
    val chip: Color,
    val muted: Color,
    val secondary: Color,
    val codeSurface: Color,
    val codeBorder: Color,
    val inlineCode: Color,
    val composerSend: Color,
    val control: Color,
    val outline: Color,
    val glass: Color,
)

private val lightOx = OxColors(
    conversationSurface = Color.White,
    bubble = Color(0xFFF3F3F3),
    chip = Color(0xFFF2F2F7),
    muted = Color(0xFF8E8E93),
    secondary = Color(0xFF666666),
    codeSurface = Color(0xFFF8F8F8),
    codeBorder = Color(0xFFE6E6E6),
    inlineCode = Color(0xFF909090),
    composerSend = Color(0xFFFF9500),
    control = Color.Black,
    outline = Color(0xFF8E8E93).copy(alpha = 0.18f),
    glass = Color.White.copy(alpha = 0.94f),
)

private val darkOx = OxColors(
    conversationSurface = Color(0xFF0A0A0A),
    bubble = Color(0xFF1C1C1E),
    chip = Color(0xFF2C2C2E),
    muted = Color(0xFF9A9A9A),
    secondary = Color(0xFF9A9A9A),
    codeSurface = Color(0xFF0A0A0A),
    codeBorder = Color(0xFF2C2C2E),
    inlineCode = Color(0xFF9A9A9A),
    composerSend = Color(0xFFFF9500),
    control = Color(0xFFF5A030),
    outline = Color(0xFF9A9A9A).copy(alpha = 0.18f),
    glass = Color(0xFF1C1C1E).copy(alpha = 0.94f),
)

val LocalOxColors = staticCompositionLocalOf { lightOx }

object OxSpacing {
    val xs = 4.dp
    val sm = 8.dp
    val md = 12.dp
    val lg = 16.dp
    val xl = 24.dp
    val xxl = 32.dp
    val transcript = 20.dp
    val touch = 44.dp
    val readable = 700.dp
}

private val lightScheme = lightColorScheme(
    primary = Color(0xFFFFA500),
    onPrimary = Color.White,
    primaryContainer = Color(0xFFFFE2B0),
    onPrimaryContainer = Color(0xFF3D2600),
    secondary = Color(0xFF666666),
    background = Color(0xFFF2F2F7),
    onBackground = Color.Black,
    surface = Color.White,
    onSurface = Color.Black,
    surfaceVariant = Color(0xFFF2F2F7),
    onSurfaceVariant = Color(0xFF8E8E93),
    surfaceContainerLowest = Color.White,
    surfaceContainerLow = Color.White,
    surfaceContainer = Color.White,
    surfaceContainerHigh = Color.White,
    surfaceContainerHighest = Color(0xFFF2F2F7),
    outline = Color(0xFFC7C7CC),
    outlineVariant = Color(0xFFE5E5EA),
    error = Color(0xFFB8422E),
    onError = Color.White,
    errorContainer = Color(0xFFFBE9E5),
    onErrorContainer = Color(0xFF5C1E13),
)

private val darkScheme = darkColorScheme(
    primary = Color(0xFFF5A030),
    onPrimary = Color.White,
    primaryContainer = Color(0xFF5C3B00),
    onPrimaryContainer = Color(0xFFFFE2B0),
    secondary = Color(0xFF9A9A9A),
    background = Color(0xFF0A0A0A),
    onBackground = Color(0xFFECECEC),
    surface = Color(0xFF1C1C1E),
    onSurface = Color(0xFFECECEC),
    surfaceVariant = Color(0xFF2C2C2E),
    onSurfaceVariant = Color(0xFF9A9A9A),
    surfaceContainerLowest = Color(0xFF0A0A0A),
    surfaceContainerLow = Color(0xFF1C1C1E),
    surfaceContainer = Color(0xFF1C1C1E),
    surfaceContainerHigh = Color(0xFF2C2C2E),
    surfaceContainerHighest = Color(0xFF2C2C2E),
    outline = Color(0xFF48484A),
    outlineVariant = Color(0xFF38383A),
    error = Color(0xFFE25A45),
    onError = Color.White,
    errorContainer = Color(0xFF3A1712),
    onErrorContainer = Color(0xFFFFD7CF),
)

private val sans = FontFamily.Default

private val typography = Typography(
    displayLarge = TextStyle(fontFamily = sans, fontWeight = FontWeight.Bold, fontSize = 34.sp, lineHeight = 41.sp),
    headlineMedium = TextStyle(fontFamily = sans, fontWeight = FontWeight.Bold, fontSize = 28.sp, lineHeight = 34.sp),
    headlineSmall = TextStyle(fontFamily = sans, fontWeight = FontWeight.SemiBold, fontSize = 22.sp, lineHeight = 28.sp),
    titleLarge = TextStyle(fontFamily = sans, fontWeight = FontWeight.SemiBold, fontSize = 20.sp, lineHeight = 25.sp),
    titleMedium = TextStyle(fontFamily = sans, fontWeight = FontWeight.SemiBold, fontSize = 17.sp, lineHeight = 22.sp),
    titleSmall = TextStyle(fontFamily = sans, fontWeight = FontWeight.SemiBold, fontSize = 15.sp, lineHeight = 20.sp),
    bodyLarge = TextStyle(fontFamily = sans, fontWeight = FontWeight.Normal, fontSize = 17.sp, lineHeight = 24.sp),
    bodyMedium = TextStyle(fontFamily = sans, fontWeight = FontWeight.Normal, fontSize = 15.sp, lineHeight = 20.sp),
    bodySmall = TextStyle(fontFamily = sans, fontWeight = FontWeight.Normal, fontSize = 13.sp, lineHeight = 18.sp),
    labelLarge = TextStyle(fontFamily = sans, fontWeight = FontWeight.SemiBold, fontSize = 15.sp, lineHeight = 20.sp),
    labelMedium = TextStyle(fontFamily = sans, fontWeight = FontWeight.SemiBold, fontSize = 12.sp, lineHeight = 16.sp),
    labelSmall = TextStyle(fontFamily = sans, fontWeight = FontWeight.SemiBold, fontSize = 11.sp, lineHeight = 13.sp),
)

private val shapes = Shapes(
    extraSmall = RoundedCornerShape(8.dp),
    small = RoundedCornerShape(8.dp),
    medium = RoundedCornerShape(12.dp),
    large = RoundedCornerShape(18.dp),
    extraLarge = RoundedCornerShape(24.dp),
)

@Composable
fun OxTheme(appearance: Appearance = Appearance.System, content: @Composable () -> Unit) {
    val dark = when (appearance) {
        Appearance.System -> isSystemInDarkTheme()
        Appearance.Light -> false
        Appearance.Dark -> true
    }
    val scheme = if (dark) darkScheme else lightScheme
    CompositionLocalProvider(LocalOxColors provides if (dark) darkOx else lightOx) {
        MaterialTheme(colorScheme = scheme, typography = typography, shapes = shapes) {
            CompositionLocalProvider(LocalContentColor provides scheme.onSurface, content = content)
        }
    }
}
