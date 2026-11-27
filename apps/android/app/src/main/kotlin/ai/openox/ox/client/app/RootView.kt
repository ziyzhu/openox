package ai.openox.ox.client.app

import ai.openox.ox.R
import ai.openox.ox.android.Platform
import ai.openox.ox.android.SharedContent
import ai.openox.ox.client.ConversationListState
import ai.openox.ox.client.HostState
import ai.openox.ox.client.HostViewModel
import ai.openox.ox.client.ProvidersState
import ai.openox.ox.client.features.conversation.ChatEnvironment
import ai.openox.ox.client.features.conversation.ChatScreen
import ai.openox.ox.client.features.conversation.ChatViewModel
import ai.openox.ox.client.features.conversation.ConversationActions
import ai.openox.ox.client.features.conversation.SidebarScreen
import ai.openox.ox.client.features.files.FilesPage
import ai.openox.ox.client.features.onboarding.HostUnavailable
import ai.openox.ox.client.features.profile.MemoryPage
import ai.openox.ox.client.features.profile.ProfilePage
import ai.openox.ox.client.features.services.RepositoriesPage
import ai.openox.ox.client.features.services.ServicesPage
import ai.openox.ox.client.features.settings.Appearance
import ai.openox.ox.client.features.settings.LogsPage
import ai.openox.ox.client.features.settings.SettingsEnvironment
import ai.openox.ox.client.features.settings.SettingsPage
import ai.openox.ox.client.features.settings.SettingsScreen
import ai.openox.ox.client.features.settings.SettingsViewModel
import ai.openox.ox.client.features.skills.SkillsPage
import ai.openox.ox.client.ui.ConfirmDialog
import ai.openox.ox.client.ui.TextDialog
import ai.openox.ox.runtime.services.Services
import ai.openox.ox.runtime.services.string
import ai.openox.ox.platform.models.HostEndpoint
import ai.openox.ox.remote.ConversationRow
import androidx.compose.animation.AnimatedContentTransitionScope
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.ViewModelStoreOwner
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavBackStackEntry
import androidx.navigation.NavHostController
import androidx.navigation.compose.composable
import androidx.navigation.compose.navigation
import androidx.navigation.toRoute

@Composable
internal fun MainScreen(
    hostModel: HostViewModel,
    host: HostState,
    session: ChatSession,
    sidebarOpen: Boolean,
    platform: Platform,
    share: SharedContent?,
    onShareConsumed: () -> Unit,
    onSidebar: (Boolean) -> Unit,
    onOpen: (String?) -> Unit,
    onSettings: () -> Unit,
    onChangeHost: () -> Unit,
) {
    val list by hostModel.conversations.collectAsStateWithLifecycle()
    val providers by hostModel.providers.collectAsStateWithLifecycle()
    val skills by hostModel.skills.collectAsStateWithLifecycle()
    val services by hostModel.services.collectAsStateWithLifecycle()
    var renaming by remember { mutableStateOf<ConversationRow?>(null) }
    var deleting by remember { mutableStateOf<ConversationRow?>(null) }
    var currentId by remember { mutableStateOf(session.id) }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(hostModel, lifecycle) { lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) { hostModel.observeHost() } }
    val client = (host as? HostState.Connected)?.client
    CompactPages(
        sidebarOpen = sidebarOpen,
        onSidebarOpen = onSidebar,
        sidebar = {
            SidebarScreen(
                host = host,
                list = list,
                currentId = currentId,
                actions = ConversationActions(
                    pin = if (hostModel.supports("conversations.pin")) hostModel::pin else null,
                    rename = if (hostModel.supports("conversations.rename")) ({ renaming = it }) else null,
                    delete = if (hostModel.supports("conversations.delete")) ({ deleting = it }) else null,
                ),
                onRefresh = hostModel::refreshConversations,
                onOpen = { onOpen(it.id) },
                onNew = { onOpen(null) },
                onSettings = onSettings,
            )
        },
        chat = {
            if (client == null) {
                HostUnavailable(host, hostModel::retry, onChangeHost)
            } else {
                val store = remember(session, client) { ViewModelStore() }
                DisposableEffect(store) { onDispose { store.clear() } }
                val owner = remember(store) { object : ViewModelStoreOwner { override val viewModelStore = store } }
                val defaultModel = (providers as? ProvidersState.Loaded)?.defaultModel
                val chat = viewModel(owner, key = "chat") { ChatViewModel(client, session.id, defaultModel) }
                LaunchedEffect(chat, share) {
                    when {
                        share == null -> Unit
                        session.id != null || !chat.state.value.isDraft -> onOpen(null)
                        else -> {
                            chat.updateDraft(share.text)
                            platform.onAttachments = chat::addAttachments
                            platform.import(share.uris)
                            onShareConsumed()
                        }
                    }
                }
                ChatScreen(
                    model = chat,
                    environment = ChatEnvironment(
                        providers = providers,
                        skills = skills,
                        services = services,
                        loadProviders = hostModel::loadProviders,
                        loadServices = hostModel::loadServices,
                        onProvidersChanged = (hostModel::reloadProviders).takeIf { host.endpoint is HostEndpoint.Local },
                        onOpenSidebar = {
                            hostModel.refreshConversations()
                            onSidebar(true)
                        },
                        onOpenConversation = { onOpen(it) },
                        onNewConversation = {
                            hostModel.refreshConversations()
                            onOpen(null)
                        },
                        onConversationChanged = { id ->
                            currentId = id
                            hostModel.openConversationId = id
                        },
                    ),
                    platform = platform,
                )
            }
        },
    )
    renaming?.let { row ->
        TextDialog(platform.string(R.string.rename), row.title, platform.string(R.string.save), "sidebar.rename", { hostModel.rename(row, it) }) { renaming = null }
    }
    deleting?.let { row ->
        ConfirmDialog(platform.string(R.string.delete_conversation_title), platform.string(R.string.delete_conversation_message), platform.string(R.string.delete),
            "sidebar.delete", onConfirm = {
                hostModel.delete(row)
                if (row.id == currentId) onOpen(null)
            }, onDismiss = { deleting = null })
    }
    LaunchedEffect(list) {
        val error = (list as? ConversationListState.Loaded)?.refreshError
        if (error != null) platform.error(error)
    }
}

internal fun androidx.navigation.NavGraphBuilder.settingsGraph(
    navigation: NavHostController,
    hostModel: HostViewModel,
    platform: Platform,
    appearance: Appearance,
    onAppearance: (Appearance) -> Unit,
    onChangeHost: () -> Unit,
) {
    navigation<SettingsGraph>(
        startDestination = SettingsRoot,
        enterTransition = { slideIntoContainer(AnimatedContentTransitionScope.SlideDirection.Up, slide) },
        popExitTransition = { slideOutOfContainer(AnimatedContentTransitionScope.SlideDirection.Down, slide) },
    ) {
        composable<SettingsRoot> { entry ->
            SettingsHost(navigation, entry, hostModel) { model ->
                val host by hostModel.host.collectAsStateWithLifecycle()
                val providers by hostModel.providers.collectAsStateWithLifecycle()
                val services by hostModel.services.collectAsStateWithLifecycle()
                SettingsScreen(
                    model,
                    SettingsEnvironment(
                        host = host,
                        providers = providers,
                        services = services,
                        appearance = appearance,
                        onAppearance = onAppearance,
                        onChangeHost = onChangeHost,
                        onProvidersChanged = hostModel::reloadProviders,
                        onOpen = { page ->
                            navigation.navigate(
                                when (page) {
                                    SettingsPage.Profile -> ProfileRoute
                                    SettingsPage.Memory -> MemoryRoute
                                    SettingsPage.Files -> FilesRoute
                                    SettingsPage.Skills -> SkillsRoute
                                    SettingsPage.Services -> ServicesRoute
                                    SettingsPage.Repositories -> RepositoriesRoute
                                    SettingsPage.Logs -> LogsRoute
                                },
                            )
                        },
                        onClose = { navigation.popBackStack(SettingsGraph, inclusive = true) },
                    ),
                    platform,
                )
            }
        }
        composable<ProfileRoute> { entry ->
            SettingsHost(navigation, entry, hostModel) { model ->
                ProfilePage(model, onOpen = { page ->
                    navigation.navigate(
                        when (page) {
                            SettingsPage.Memory -> MemoryRoute
                            SettingsPage.Files -> FilesRoute
                            else -> SkillsRoute
                        },
                    )
                }, onBack = { navigation.popBackStack() })
            }
        }
        composable<MemoryRoute> { entry ->
            SettingsHost(navigation, entry, hostModel) { model -> MemoryPage(model, platform) { navigation.popBackStack() } }
        }
        composable<FilesRoute> { entry -> SettingsHost(navigation, entry, hostModel) { model -> FilesPage(model) { navigation.popBackStack() } } }
        composable<SkillsRoute> {
            val skills by hostModel.skills.collectAsStateWithLifecycle()
            SkillsPage(skills, hostModel::loadSkills) { navigation.popBackStack() }
        }
        composable<ServicesRoute> {
            val services by hostModel.services.collectAsStateWithLifecycle()
            ServicesPage(services, hostModel::loadServices, onReload = { hostModel.reloadService(it) }, onRefreshAuth = { hostModel.refreshServiceAuth(it) }) { navigation.popBackStack() }
        }
        composable<RepositoriesRoute> { entry -> SettingsHost(navigation, entry, hostModel) { model -> RepositoriesPage(model) { navigation.popBackStack() } } }
        composable<LogsRoute> { entry -> SettingsHost(navigation, entry, hostModel) { model -> LogsPage(model) { navigation.popBackStack() } } }
    }
}

@Composable
private fun SettingsHost(navigation: NavHostController, entry: NavBackStackEntry, hostModel: HostViewModel, content: @Composable (SettingsViewModel) -> Unit) {
    val host by hostModel.host.collectAsStateWithLifecycle()
    val client = (host as? HostState.Connected)?.client ?: return
    val parent = remember(entry) { navigation.getBackStackEntry(SettingsGraph) }
    content(viewModel(parent, key = client.endpoint.url) { SettingsViewModel(client) })
}
