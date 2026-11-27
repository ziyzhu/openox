package ai.openox.ox.client.app

import ai.openox.ox.android.SharedContent
import ai.openox.ox.android.rememberPlatform
import ai.openox.ox.client.HostEvent
import ai.openox.ox.client.HostViewModel
import ai.openox.ox.client.features.conversation.CompletionBanner
import ai.openox.ox.client.features.onboarding.HostScreen
import ai.openox.ox.client.features.settings.Appearance
import ai.openox.ox.client.ui.BrowserOverlay
import ai.openox.ox.client.ui.OxTheme
import ai.openox.ox.client.ui.Toast
import ai.openox.ox.client.ui.ToastHost
import ai.openox.ox.client.ui.ToastState
import ai.openox.ox.remote.ConversationRow
import android.app.Application
import androidx.compose.animation.AnimatedContentTransitionScope
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.Saver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.unit.IntOffset
import androidx.core.content.edit
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.navigation
import androidx.navigation.compose.rememberNavController
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.Serializable

@Serializable data object HostRoute

@Serializable data object MainRoute

@Serializable data object SettingsGraph

@Serializable data object SettingsRoot

@Serializable data object ProfileRoute

@Serializable data object MemoryRoute

@Serializable data object FilesRoute

@Serializable data object SkillsRoute

@Serializable data object ServicesRoute

@Serializable data object RepositoriesRoute

@Serializable data object LogsRoute

internal data class ChatSession(val id: String?, val nonce: Long)

internal val slide = spring<IntOffset>(dampingRatio = Spring.DampingRatioNoBouncy, stiffness = Spring.StiffnessMediumLow)

@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun OxApp(shared: StateFlow<SharedContent?>, onShareConsumed: () -> Unit, hostModel: HostViewModel = viewModel()) {
    val context = LocalContext.current
    val preferences = remember { context.getSharedPreferences("app", Application.MODE_PRIVATE) }
    var appearance by remember { mutableStateOf(Appearance.entries.firstOrNull { it.key == preferences.getString("appearance", null) } ?: Appearance.System) }
    OxTheme(appearance) {
        val toasts = remember { ToastState() }
        val platform = rememberPlatform(toasts)
        val navigation = rememberNavController()
        val host by hostModel.host.collectAsStateWithLifecycle()
        val start: Any = remember { if (hostModel.savedAddress.isEmpty()) HostRoute else MainRoute }
        var banner by remember { mutableStateOf<ConversationRow?>(null) }
        var session by rememberSaveable(stateSaver = sessionSaver) { mutableStateOf(ChatSession(null, 0)) }
        var sidebarOpen by rememberSaveable { mutableStateOf(false) }
        var bannerNonce by remember { mutableLongStateOf(0) }
        val pendingShare by shared.collectAsStateWithLifecycle()

        val open = { id: String? ->
            session = ChatSession(id, session.nonce + 1)
            sidebarOpen = false
        }

        LaunchedEffect(hostModel) {
            hostModel.events.collect { event ->
                when (event) {
                    is HostEvent.Completed -> { banner = event.row; bannerNonce++ }
                    is HostEvent.Toast -> if (event.error) platform.error(event.message) else platform.toast(event.message)
                }
            }
        }
        LaunchedEffect(bannerNonce) {
            delay(8_000)
            banner = null
        }
        LaunchedEffect(pendingShare) {
            if (pendingShare != null) navigation.popBackStack(MainRoute, inclusive = false)
        }

        Box(Modifier.fillMaxSize().semantics { testTagsAsResourceId = true }) {
            BrowserOverlay()
            NavHost(
                navController = navigation,
                startDestination = start,
                enterTransition = { slideIntoContainer(AnimatedContentTransitionScope.SlideDirection.Start, slide) },
                exitTransition = { slideOutOfContainer(AnimatedContentTransitionScope.SlideDirection.Start, slide) + fadeOut() },
                popEnterTransition = { slideIntoContainer(AnimatedContentTransitionScope.SlideDirection.End, slide) + fadeIn() },
                popExitTransition = { slideOutOfContainer(AnimatedContentTransitionScope.SlideDirection.End, slide) },
            ) {
                composable<HostRoute> {
                    HostScreen(hostModel) { navigation.navigate(MainRoute) { popUpTo(HostRoute) { inclusive = true } } }
                }
                val changeHost = {
                    hostModel.forget()
                    navigation.navigate(HostRoute) { popUpTo(0) }
                }
                composable<MainRoute>(
                    enterTransition = { fadeIn() },
                    popEnterTransition = { slideIntoContainer(AnimatedContentTransitionScope.SlideDirection.Down, slide) },
                    exitTransition = { fadeOut() },
                ) {
                    MainScreen(
                        hostModel = hostModel,
                        host = host,
                        session = session,
                        sidebarOpen = sidebarOpen,
                        platform = platform,
                        share = pendingShare,
                        onShareConsumed = onShareConsumed,
                        onSidebar = { sidebarOpen = it },
                        onOpen = open,
                        onSettings = { navigation.navigate(SettingsGraph) },
                        onChangeHost = changeHost,
                    )
                }
                settingsGraph(navigation, hostModel, platform, appearance, { option ->
                    appearance = option
                    preferences.edit { putString("appearance", option.key) }
                }, onChangeHost = changeHost)
            }
            ToastHost(toasts, Modifier.align(Alignment.TopCenter))
            CompletionBanner(banner, { row -> banner = null; open(row.id) }, Modifier.align(Alignment.TopCenter))
        }
    }
}

private val sessionSaver = Saver<ChatSession, List<Any?>>(
    save = { listOf(it.id, it.nonce) },
    restore = { ChatSession(it[0] as String?, it[1] as Long) },
)
