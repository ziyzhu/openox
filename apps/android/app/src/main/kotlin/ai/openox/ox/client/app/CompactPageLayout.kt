package ai.openox.ox.client.app

import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.unit.IntOffset
import kotlin.math.roundToInt
import kotlinx.coroutines.launch

private val pageSpring = spring<Float>(dampingRatio = Spring.DampingRatioNoBouncy, stiffness = Spring.StiffnessMediumLow)

@Composable
fun CompactPages(
    sidebarOpen: Boolean,
    onSidebarOpen: (Boolean) -> Unit,
    sidebar: @Composable () -> Unit,
    chat: @Composable () -> Unit,
) {
    val progress = remember { Animatable(if (sidebarOpen) 1f else 0f) }
    val scope = rememberCoroutineScope()
    val focusManager = LocalFocusManager.current
    LaunchedEffect(sidebarOpen) {
        if (sidebarOpen) focusManager.clearFocus()
        progress.animateTo(if (sidebarOpen) 1f else 0f, pageSpring)
    }
    BackHandler(enabled = sidebarOpen) { onSidebarOpen(false) }
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val width = constraints.maxWidth.toFloat().coerceAtLeast(1f)
        val drag = rememberDraggableState { delta -> scope.launch { progress.snapTo((progress.value + delta / width).coerceIn(0f, 1f)) } }
        Box(
            Modifier.fillMaxSize().draggable(
                state = drag,
                orientation = Orientation.Horizontal,
                onDragStarted = { focusManager.clearFocus() },
                onDragStopped = { velocity ->
                    val open = when {
                        velocity > FLING -> true
                        velocity < -FLING -> false
                        else -> progress.value > if (sidebarOpen) 0.7f else 0.3f
                    }
                    if (open == sidebarOpen) progress.animateTo(if (open) 1f else 0f, pageSpring, velocity / width) else onSidebarOpen(open)
                },
            ),
        ) {
            Box(Modifier.fillMaxSize().offset { IntOffset(((progress.value - 1f) * width).roundToInt(), 0) }) { sidebar() }
            Box(Modifier.fillMaxSize().offset { IntOffset((progress.value * width).roundToInt(), 0) }) {
                chat()
                Box(
                    Modifier.fillMaxSize()
                        .graphicsLayer { alpha = progress.value * 0.15f }
                        .background(Color.Black),
                )
            }
        }
    }
}

private const val FLING = 1200f
