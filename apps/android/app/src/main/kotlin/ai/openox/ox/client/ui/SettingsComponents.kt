package ai.openox.ox.client.ui

import ai.openox.ox.R
import ai.openox.ox.runtime.services.string
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

@Composable
fun SettingsScaffold(
    title: String,
    tag: String,
    onBack: (() -> Unit)? = null,
    onClose: (() -> Unit)? = null,
    action: (@Composable () -> Unit)? = null,
    scroll: Boolean = true,
    content: @Composable ColumnScope.() -> Unit,
) {
    Column(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background).testTag(tag)) {
        Box(Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = OxSpacing.lg, vertical = OxSpacing.sm)) {
            onBack?.let { GlassCircleButton(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.back), "$tag.back", Modifier.align(Alignment.CenterStart), onClick = it) }
            Text(title, style = MaterialTheme.typography.titleMedium, modifier = Modifier.align(Alignment.Center).widthIn(max = 240.dp), maxLines = 1, overflow = TextOverflow.Ellipsis)
            Box(Modifier.align(Alignment.CenterEnd)) {
                when {
                    action != null -> action()
                    onClose != null -> GlassCircleButton(Icons.Filled.Close, stringResource(R.string.close), "settings.close", onClick = onClose)
                }
            }
        }
        val body = Modifier.fillMaxWidth().weight(1f)
        Column(
            modifier = (if (scroll) body.verticalScroll(rememberScrollState()) else body).navigationBarsPadding().padding(horizontal = 20.dp, vertical = OxSpacing.lg),
            verticalArrangement = Arrangement.spacedBy(OxSpacing.xxl),
            content = content,
        )
    }
}

@Composable
fun SettingsGroup(header: String?, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(OxSpacing.sm)) {
        header?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = LocalOxColors.current.secondary, modifier = Modifier.padding(start = 20.dp)) }
        Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(24.dp)).background(MaterialTheme.colorScheme.surface), content = content)
    }
}

@Composable
fun SettingsRow(
    icon: ImageVector?,
    title: String,
    subtitle: String? = null,
    value: String? = null,
    tag: String,
    tint: androidx.compose.ui.graphics.Color = MaterialTheme.colorScheme.onSurface,
    chevron: Boolean = true,
    trailing: (@Composable () -> Unit)? = null,
    leading: (@Composable () -> Unit)? = null,
    onClick: (() -> Unit)?,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(horizontal = 20.dp, vertical = 14.dp)
            .testTag(tag),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(OxSpacing.md),
    ) {
        leading?.invoke()
        icon?.let { Icon(it, null, tint = if (tint == MaterialTheme.colorScheme.onSurface) LocalOxColors.current.secondary else tint, modifier = Modifier.size(22.dp)) }
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyLarge, color = tint)
            subtitle?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = LocalOxColors.current.secondary, maxLines = 2, overflow = TextOverflow.Ellipsis) }
        }
        value?.let { Text(it, style = MaterialTheme.typography.bodyLarge, color = LocalOxColors.current.secondary, maxLines = 1) }
        trailing?.invoke()
        if (chevron && onClick != null) Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = LocalOxColors.current.muted, modifier = Modifier.size(20.dp))
    }
}

@Composable
fun LoadingRow() {
    Box(Modifier.fillMaxWidth().height(64.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator(Modifier.size(22.dp), strokeWidth = 2.dp) }
}

@Composable
fun MessageRow(text: String) {
    Text(text, style = MaterialTheme.typography.bodyLarge, color = LocalOxColors.current.secondary, modifier = Modifier.padding(horizontal = 20.dp, vertical = 14.dp))
}

@Composable
fun RowDivider() {
    HorizontalDivider(Modifier.padding(start = 20.dp), color = MaterialTheme.colorScheme.outlineVariant)
}

@Composable
fun Gap() = Spacer(Modifier.height(OxSpacing.sm))
