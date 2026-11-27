plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

val repositoryRoot = rootProject.projectDir.resolve("../..")

fun configuredApplicationId(): String {
    val local = repositoryRoot.resolve("apps/ios/Local.xcconfig")
    val fromLocal = local.takeIf { it.isFile }?.readLines()
        ?.firstNotNullOfOrNull { Regex("""^\s*OX_BUNDLE_IDENTIFIER\s*=\s*(\S+)""").find(it)?.groupValues?.get(1) }
    if (fromLocal != null) return fromLocal
    val ci = repositoryRoot.resolve(".github/ci.json").readText()
    return Regex(""""iosBundleIdentifier"\s*:\s*"([^"]+)"""").find(ci)?.groupValues?.get(1)
        ?: error("Missing iosBundleIdentifier in .github/ci.json")
}

val releaseKeystore = providers.environmentVariable("OX_ANDROID_KEYSTORE").orNull

android {
    namespace = "ai.openox.ox"
    compileSdk {
        version = release(37) { minorApiLevel = 2 }
    }

    defaultConfig {
        applicationId = configuredApplicationId()
        minSdk = 29
        targetSdk = 37
        versionCode = 1
        versionName = "0.1.0"
    }

    signingConfigs {
        if (releaseKeystore != null) {
            create("release") {
                storeFile = file(releaseKeystore)
                storePassword = providers.environmentVariable("OX_ANDROID_KEYSTORE_PASSWORD").get()
                keyAlias = providers.environmentVariable("OX_ANDROID_KEY_ALIAS").get()
                keyPassword = providers.environmentVariable("OX_ANDROID_KEY_PASSWORD").get()
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    lint {
        warningsAsErrors = true
        abortOnError = true
        disable += setOf("GradleDependency", "NewerVersionAvailable", "AndroidGradlePluginVersion", "ObsoleteSdkInt")
    }
}

kotlin {
    compilerOptions {
        allWarningsAsErrors = true
    }
}

dependencies {
    implementation(platform(libs.compose.bom))
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.navigation.compose)
    implementation(libs.compose.ui)
    implementation(libs.compose.ui.tooling.preview)
    implementation(libs.compose.material3)
    implementation(libs.compose.material.icons)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.okhttp)
    implementation(libs.markdown.m3)
    implementation(libs.quickjs)
    implementation(libs.webkit)
    implementation(libs.browser)
    implementation(libs.androidx.sqlite.bundled)
    debugImplementation(libs.compose.ui.tooling)
}

abstract class AgentBundleTask : DefaultTask() {
    @get:InputFile
    abstract val harness: RegularFileProperty

    @get:InputFile
    abstract val prompts: RegularFileProperty

    @get:InputFile
    abstract val extraction: RegularFileProperty

    @get:InputFile
    abstract val providers: RegularFileProperty

    @get:InputFile
    abstract val validation: RegularFileProperty

    @get:InputFile
    abstract val runtime: RegularFileProperty

    @get:InputFiles
    abstract val contracts: ConfigurableFileCollection

    @get:InputDirectory
    abstract val serviceBundle: DirectoryProperty

    @get:OutputDirectory
    abstract val output: DirectoryProperty

    @TaskAction
    fun copy() {
        val target = output.get().asFile.resolve("agent").apply { mkdirs() }
        harness.get().asFile.copyTo(target.resolve("harness.js"), overwrite = true)
        prompts.get().asFile.copyTo(target.resolve("prompts.js"), overwrite = true)
        extraction.get().asFile.copyTo(target.resolve("web-extraction.js"), overwrite = true)
        providers.get().asFile.copyTo(target.resolve("providers.json"), overwrite = true)
        validation.get().asFile.copyTo(target.resolve("service-validation.js"), overwrite = true)
        runtime.get().asFile.copyTo(target.resolve("service-runtime.js"), overwrite = true)
        contracts.forEach { file -> file.copyTo(target.resolve("contracts/${file.parentFile.name}.json"), overwrite = true) }
        val bundle = output.get().asFile.resolve("services").apply { deleteRecursively() }
        val source = serviceBundle.get().asFile
        listOf("skills", "web").forEach { name -> source.resolve(name).copyRecursively(bundle.resolve(name), overwrite = true) }
        source.resolve("repository.json").copyTo(bundle.resolve("repository.json"), overwrite = true)
        bundle.resolve("index.txt").writeText(bundle.walkTopDown().filter { it.isFile }.map { it.relativeTo(bundle).invariantSeparatorsPath }.sorted().joinToString("\n"))
    }
}

val agentBundle = tasks.register<AgentBundleTask>("agentBundle") {
    harness.set(rootProject.layout.projectDirectory.file("../shared/Resources/PiDurable.bundle/harness.js"))
    prompts.set(rootProject.layout.projectDirectory.file("../shared/Resources/PiDurable.bundle/prompts.js"))
    extraction.set(rootProject.layout.projectDirectory.file("../shared/Resources/PiDurable.bundle/web-extraction.js"))
    providers.set(rootProject.layout.projectDirectory.file("../shared/Runtime/ModelProviders/providers.json"))
    validation.set(rootProject.layout.projectDirectory.file("../shared/Resources/PiDurable.bundle/service-validation.js"))
    runtime.set(rootProject.layout.projectDirectory.file("../shared/Runtime/Services/Web/ServiceActionRuntime.js"))
    serviceBundle.set(rootProject.layout.projectDirectory.dir("../shared/Resources/OxServices.bundle"))
    contracts.from(listOf("fs", "web", "conversation", "service", "repository").map { rootProject.layout.projectDirectory.file("../../packages/agent/src/functions/$it/contracts.json") })
}

androidComponents {
    onVariants { variant ->
        variant.sources.assets?.addGeneratedSourceDirectory(agentBundle, AgentBundleTask::output)
    }
}
