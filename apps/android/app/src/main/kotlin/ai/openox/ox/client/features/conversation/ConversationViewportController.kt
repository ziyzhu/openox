package ai.openox.ox.client.features.conversation

import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.foundation.gestures.animateScrollBy
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.withFrameNanos

internal class TranscriptPin(private val list: LazyListState) {
    var key by mutableStateOf<String?>(null)
        private set
    var runway by mutableIntStateOf(0)
        private set

    suspend fun pin(key: String, index: Int) {
        this.key = key
        runway = list.layoutInfo.viewportSize.height
        withFrameNanos { }
        list.animateScrollToItem(index)
    }

    fun measure() {
        val key = key ?: return
        val info = list.layoutInfo
        val visible = info.visibleItemsInfo
        val anchor = visible.firstOrNull { it.key == key } ?: return
        val end = visible.lastOrNull() ?: return
        if (end.key != RUNWAY && end.index != info.totalItemsCount - 1) {
            runway = 0
            return
        }
        val content = visible.lastOrNull { it.key != RUNWAY } ?: return
        val spacing = if (end.key == RUNWAY) info.mainAxisItemSpacing else 0
        val available = info.viewportEndOffset - info.afterContentPadding
        runway = (available - (content.offset + content.size - anchor.offset) - spacing).coerceAtLeast(0)
    }
}

@Composable
internal fun rememberTranscriptPin(list: LazyListState): TranscriptPin {
    val pin = remember(list) { TranscriptPin(list) }
    LaunchedEffect(pin) { snapshotFlow { list.layoutInfo }.collect { pin.measure() } }
    return pin
}

@Composable
internal fun StickToEndEffect(list: LazyListState, pinned: Boolean) {
    val following by rememberUpdatedState(!pinned)
    LaunchedEffect(list) {
        var previous: Pair<Int, Boolean>? = null
        snapshotFlow { list.layoutInfo.viewportSize.height to !list.canScrollForward }.collect { current ->
            val before = previous
            previous = current
            if (before == null || list.isScrollInProgress || !before.second || current.second) return@collect
            val resized = before.first != current.first
            if (resized || following) list.scrollToEnd(animated = false)
        }
    }
}

internal suspend fun LazyListState.scrollToEnd(animated: Boolean) {
    val last = layoutInfo.totalItemsCount - 1
    if (last < 0) return
    if (layoutInfo.visibleItemsInfo.none { it.index == last }) {
        if (animated) animateScrollToItem(last) else scrollToItem(last)
    }
    val end = layoutInfo.visibleItemsInfo.lastOrNull { it.index == last } ?: return
    val distance = (end.offset + end.size - (layoutInfo.viewportEndOffset - layoutInfo.afterContentPadding)).toFloat()
    if (distance <= 0f) return
    if (animated) animateScrollBy(distance, spring(stiffness = Spring.StiffnessMediumLow)) else scrollBy(distance)
}
