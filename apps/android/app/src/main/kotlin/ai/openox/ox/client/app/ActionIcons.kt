package ai.openox.ox.client.app

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color

@Composable
fun OxMark(modifier: Modifier = Modifier, color: Color, faint: Color) {
    Canvas(modifier) {
        val cell = size.minDimension / 4f
        val full = cell * 0.79f
        val small = cell * 0.59f
        val strong = setOf(0 to 0, 3 to 0, 0 to 1, 1 to 1, 2 to 1, 3 to 1, 1 to 2, 2 to 2, 1 to 3, 2 to 3)
        for (row in 0..3) for (column in 0..3) {
            val solid = (column to row) in strong
            val side = if (solid) full else small
            val center = Offset(cell * (column + 0.5f), cell * (row + 0.5f))
            drawRoundRect(
                color = if (solid) color else faint,
                topLeft = Offset(center.x - side / 2, center.y - side / 2),
                size = Size(side, side),
                cornerRadius = CornerRadius(side * 0.29f),
            )
        }
    }
}
