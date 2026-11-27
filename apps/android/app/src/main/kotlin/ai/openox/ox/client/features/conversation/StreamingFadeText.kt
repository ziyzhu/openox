package ai.openox.ox.client.features.conversation

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.withFrameNanos
import kotlin.math.ceil
import kotlinx.coroutines.flow.first

@Composable
fun rememberRevealedText(text: String, live: Boolean): String {
    val latest by rememberUpdatedState(text)
    var shown by remember { mutableIntStateOf(if (live) 0 else text.length) }
    LaunchedEffect(Unit) {
        var rate = 0f
        var known = latest.length
        var arrivedAt = 0L
        while (true) {
            snapshotFlow { shown < latest.length }.first { it }
            var last = withFrameNanos { it }
            while (shown < latest.length) {
                val now = withFrameNanos { it }
                val target = latest
                if (target.length > known) {
                    if (arrivedAt != 0L) {
                        val gap = ((now - arrivedAt) / 1_000_000_000f).coerceIn(0.05f, 2f)
                        rate = rate * 0.6f + (target.length - known) / gap * 0.4f
                    }
                    known = target.length
                    arrivedAt = now
                }
                val paragraph = shown - target.lastIndexOf("\n\n", shown)
                if (now - last < maxOf(REVEAL_TICK_NANOS, paragraph * NANOS_PER_PARAGRAPH_CHAR)) continue
                val seconds = ((now - last) / 1_000_000_000f).coerceAtMost(0.1f)
                val backlog = target.length - shown
                val step = ceil((rate + backlog / CATCH_UP_SECONDS) * seconds).toInt().coerceAtLeast(1)
                shown = MarkdownBlocks.wordEnd(target, maxOf(shown + step, target.length - MAX_LAG))
                last = now
            }
        }
    }
    if (shown >= text.length) return text
    return MarkdownBlocks.withoutOpenMarker(text.substring(0, shown))
}

private const val CATCH_UP_SECONDS = 0.6f

private const val MAX_LAG = 1200

private const val REVEAL_TICK_NANOS = 30_000_000L

private const val NANOS_PER_PARAGRAPH_CHAR = 12_000L
