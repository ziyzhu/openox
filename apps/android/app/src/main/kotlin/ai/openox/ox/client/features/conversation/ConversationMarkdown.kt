package ai.openox.ox.client.features.conversation

import ai.openox.ox.client.ui.LocalOxColors
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.mikepenz.markdown.m3.Markdown
import com.mikepenz.markdown.m3.markdownColor
import com.mikepenz.markdown.m3.markdownTypography
import com.mikepenz.markdown.model.markdownAnimations
import com.mikepenz.markdown.model.markdownAnnotator
import com.mikepenz.markdown.model.parseMarkdown
import kotlinx.coroutines.flow.first
import org.intellij.markdown.MarkdownElementTypes

@Composable
fun OxMarkdown(content: String) {
    val colors = LocalOxColors.current
    val body = MaterialTheme.typography.bodyLarge
    val heading = body.copy(fontWeight = FontWeight.SemiBold)
    val code = body.copy(fontFamily = FontFamily.Monospace, fontSize = 14.sp, lineHeight = 20.sp)
    val markdownColors = markdownColor(
        text = MaterialTheme.colorScheme.onSurface,
        codeBackground = colors.codeSurface,
        inlineCodeBackground = colors.codeSurface,
        dividerColor = colors.codeBorder,
        tableBackground = colors.codeSurface,
    )
    val typography = markdownTypography(
        h1 = heading.copy(fontSize = 22.sp, lineHeight = 28.sp),
        h2 = heading.copy(fontSize = 20.sp, lineHeight = 26.sp),
        h3 = heading,
        h4 = heading,
        h5 = heading,
        h6 = heading,
        text = body,
        paragraph = body,
        ordered = body,
        bullet = body,
        list = body,
        code = code,
        inlineCode = code.copy(fontSize = 15.sp, color = colors.inlineCode),
        quote = body.copy(color = colors.secondary),
    )
    val staticText = markdownAnimations(animateTextSize = { this })
    val literalCode = remember(typography, colors) {
        val style = typography.inlineCode.toSpanStyle().copy(background = colors.codeSurface)
        markdownAnnotator { content, child ->
            if (child.type != MarkdownElementTypes.CODE_SPAN) return@markdownAnnotator false
            withStyle(style) {
                append(' ')
                append(codeSpan(content.substring(child.startOffset, child.endOffset)))
                append(' ')
            }
            true
        }
    }
    val blocks = remember(content) { MarkdownBlocks.split(content) }
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        blocks.forEach { block ->
            val parsed = remember(block) { parseMarkdown(block) }
            Markdown(parsed, colors = markdownColors, typography = typography, annotator = literalCode, animations = staticText)
        }
    }
}

private fun codeSpan(raw: String): String {
    val fence = raw.takeWhile { it == '`' }.length
    val inner = raw.substring(fence, (raw.length - fence).coerceAtLeast(fence)).replace('\n', ' ')
    return if (inner.length > 2 && inner.startsWith(' ') && inner.endsWith(' ') && inner.isNotBlank()) inner.substring(1, inner.length - 1) else inner
}

object MarkdownBlocks {
    fun split(content: String): List<String> {
        val blocks = mutableListOf<String>()
        val current = StringBuilder()
        var fenced = false
        var blankBefore = false
        content.lineSequence().forEach { line ->
            val boundary = !fenced && blankBefore && current.isNotBlank() && line.isNotBlank() &&
                !line.first().isWhitespace() && !LIST_ITEM.containsMatchIn(line)
            if (boundary) {
                blocks += current.toString().trim('\n')
                current.clear()
            }
            if (isFence(line)) fenced = !fenced
            blankBefore = line.isBlank()
            current.append(line).append('\n')
        }
        if (current.isNotBlank()) blocks += current.toString().trimEnd()
        return blocks
    }

    fun wordEnd(text: String, from: Int): Int {
        if (from >= text.length) return text.length
        val next = text.indexOfAny(WORD_BREAKS, from)
        return if (next < 0) text.length else next
    }

    fun withoutOpenMarker(prefix: String): String {
        val lineStart = prefix.lastIndexOf('\n') + 1
        val line = prefix.substring(lineStart)
        if (prefix.lineSequence().count(::isFence) % 2 == 1) return prefix
        val body = line.length - line.trimStart().removePrefix("* ").length
        val text = line.substring(body)
        val strong = text.split("**").size - 1
        val plain = text.replace("**", "  ")
        val cuts = listOfNotNull(
            text.lastIndexOf("**").takeIf { strong % 2 == 1 },
            plain.lastIndexOf('*').takeIf { plain.count { it == '*' } % 2 == 1 },
            plain.lastIndexOf('`').takeIf { plain.count { it == '`' } % 2 == 1 },
            openLink(plain),
        )
        val cut = cuts.minOrNull() ?: return prefix
        return prefix.substring(0, lineStart + body + cut)
    }

    private fun isFence(line: String): Boolean = line.trimStart().let { it.startsWith("```") || it.startsWith("~~~") }

    private fun openLink(text: String): Int? {
        val open = text.lastIndexOf('[')
        if (open < 0) return null
        val label = text.indexOf(']', open)
        if (label < 0) return open
        if (text.getOrNull(label + 1) != '(') return null
        return open.takeIf { text.indexOf(')', label) < 0 }
    }

    private val LIST_ITEM = Regex("""^([-*+]|\d+[.)])\s""")
    private val WORD_BREAKS = charArrayOf(' ', '\n')
}
