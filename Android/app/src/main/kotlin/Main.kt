// Copyright (C) 2026 LayerTwo Labs and contributors
// Licensed under the GNU General Public License v2.0 or later
// SPDX-License-Identifier: GPL-2.0-or-later

package ecash.wallet.mobile

import skip.lib.*
import skip.model.*
import skip.foundation.*
import skip.ui.*

import android.Manifest
import android.app.Application
import android.graphics.Color as AndroidColor
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.SystemBarStyle
import androidx.activity.ComponentActivity
import androidx.appcompat.app.AppCompatActivity
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.ui.text.font.FontFamily
import androidx.core.app.ActivityCompat

internal val logger: SkipLogger = SkipLogger(subsystem = "ecash.wallet.mobile", category = "ECashWalletMobile")

private typealias AppRootView = ECashWalletMobileRootView
private typealias AppDelegate = ECashWalletMobileAppDelegate

/// AndroidAppMain is the `android.app.Application` entry point, and must match `application android:name` in the AndroidMainfest.xml file.
open class AndroidAppMain: Application {
    constructor() {
    }

    override fun onCreate() {
        super.onCreate()
        logger.info("starting app")
        ProcessInfo.launch(applicationContext)
        AppDelegate.shared.onInit()
    }

    companion object {
    }
}

/// AndroidAppMain is initial `androidx.appcompat.app.AppCompatActivity`, and must match `activity android:name` in the AndroidMainfest.xml file.
open class MainActivity: AppCompatActivity {
    constructor() {
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        logger.info("starting activity")
        UIApplication.launch(this)
        enableEdgeToEdge()

        setContent {
            val saveableStateHolder = rememberSaveableStateHolder()
            saveableStateHolder.SaveableStateProvider(true) {
                PresentationRootView(ComposeContext())
                SideEffect { saveableStateHolder.removeState(true) }
            }
        }

        AppDelegate.shared.onLaunch()

        // Example of requesting permissions on startup.
        // These must match the permissions in the AndroidManifest.xml file.
        //let permissions = listOf(
        //    Manifest.permission.ACCESS_COARSE_LOCATION,
        //    Manifest.permission.ACCESS_FINE_LOCATION
        //    Manifest.permission.CAMERA,
        //    Manifest.permission.WRITE_EXTERNAL_STORAGE,
        //)
        //let requestTag = 1
        //ActivityCompat.requestPermissions(self, permissions.toTypedArray(), requestTag)
    }

    override fun onStart() {
        logger.info("onStart")
        super.onStart()
    }

    override fun onResume() {
        super.onResume()
        // Expose the foreground activity to WalletService's platform glue (FLAG_SECURE on
        // seed-bearing screens, BiometricPrompt) — the transpiled module can't reach skip.ui.
        wallet.service.AndroidActivityHolder.current = this
        AppDelegate.shared.onResume()
    }

    override fun onPause() {
        super.onPause()
        wallet.service.AndroidActivityHolder.current = null
        AppDelegate.shared.onPause()
    }

    override fun onStop() {
        super.onStop()
        AppDelegate.shared.onStop()
    }

    override fun onDestroy() {
        super.onDestroy()
        AppDelegate.shared.onDestroy()
    }

    override fun onLowMemory() {
        super.onLowMemory()
        AppDelegate.shared.onLowMemory()
    }

    override fun onRestart() {
        logger.info("onRestart")
        super.onRestart()
    }

    override fun onSaveInstanceState(outState: android.os.Bundle): Unit = super.onSaveInstanceState(outState)

    override fun onRestoreInstanceState(bundle: android.os.Bundle) {
        // Usually you restore your state in onCreate(). It is possible to restore it in onRestoreInstanceState() as well, but not very common. (onRestoreInstanceState() is called after onStart(), whereas onCreate() is called before onStart().
        logger.info("onRestoreInstanceState")
        super.onRestoreInstanceState(bundle)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: kotlin.Array<String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        logger.info("onRequestPermissionsResult: ${requestCode}")
    }

    companion object {
    }
}

@Composable
internal fun SyncSystemBarsWithTheme() {
    val dark = MaterialTheme.colorScheme.background.luminance() < 0.5f

    val transparent = AndroidColor.TRANSPARENT
    val style = if (dark) {
        SystemBarStyle.dark(transparent)
    } else {
        SystemBarStyle.light(transparent, transparent)
    }

    val activity = LocalContext.current as? ComponentActivity
    DisposableEffect(style) {
        activity?.enableEdgeToEdge(
            statusBarStyle = style,
            navigationBarStyle = style
        )
        onDispose { }
    }
}

/// Build the brand title `Typography`. SkipUI's navigation bars take their title text style from
/// `MaterialTheme.typography` (`titleLarge` for the inline bar; `headlineLarge`→`headlineSmall` for
/// the large/medium bar), so overriding those roles here re-fonts every nav title the native
/// Compose way — without touching SkipUI. We swap ONLY the title/headline roles' `fontFamily`,
/// keeping Material's native sizes/weights, and leave body/label roles default (our SwiftUI Text
/// already sets its own fonts everywhere else).
///
/// This is the Fuse-correct place for it: a SwiftUI view body's `#if SKIP` branch never executes
/// on Android (the body bridges back to native Swift), so Compose theming must live in this
/// editable Kotlin root, not in an app-module ViewModifier.
@Composable
private fun brandTitleTypography(): Typography {
    val ctx = LocalContext.current
    return remember {
        // Space Grotesk — semibold for inline-title roles, bold for the large/headline roles
        // (mirrors the iOS UINavigationBarAppearance: inline SemiBold, large Bold).
        val semiId = ctx.resources.getIdentifier("spacegrotesk_semibold", "font", ctx.packageName)
        val boldId = ctx.resources.getIdentifier("spacegrotesk_bold", "font", ctx.packageName)
        val base = Typography()
        if (semiId == 0 || boldId == 0) {
            base
        } else {
            val semi = FontFamily(ctx.resources.getFont(semiId))
            val bold = FontFamily(ctx.resources.getFont(boldId))
            base.copy(
                titleLarge = base.titleLarge.copy(fontFamily = semi),
                titleMedium = base.titleMedium.copy(fontFamily = semi),
                titleSmall = base.titleSmall.copy(fontFamily = semi),
                headlineLarge = base.headlineLarge.copy(fontFamily = bold),
                headlineMedium = base.headlineMedium.copy(fontFamily = bold),
                headlineSmall = base.headlineSmall.copy(fontFamily = bold)
            )
        }
    }
}

/// Cap on the system font scale — the Android analog of the iOS `dynamicTypeSize(...xLarge)` clamp
/// in RootView. 1.15 ≈ Android's "Large" font setting (and ≈ iOS xLarge); "Largest" (1.3) and the
/// accessibility tiers (up to 2.0) clamp down to this so the fixed-size amount/address layouts
/// don't break. SkipUI's `.dynamicTypeSize` is unavailable (a no-op) on Android, so the clamp has
/// to be applied here at the Compose root.
private const val MAX_FONT_SCALE = 1.15f

@Composable
internal fun PresentationRootView(context: ComposeContext) {
    val colorScheme = if (isSystemInDarkTheme()) ColorScheme.dark else ColorScheme.light
    // Clamp ONLY the font scale (keep `density` so dp layout is unaffected — only text stops growing).
    val density = LocalDensity.current
    val cappedDensity = Density(density.density, density.fontScale.coerceAtMost(MAX_FONT_SCALE))
    CompositionLocalProvider(LocalDensity provides cappedDensity) {
        // Provide the brand title typography ABOVE PresentationRoot: SkipUI re-themes only the color
        // scheme inside, inheriting this typography for the top app bars.
        MaterialTheme(typography = brandTitleTypography()) {
            PresentationRoot(defaultColorScheme = colorScheme, context = context) { ctx ->
                SyncSystemBarsWithTheme()
                val contentContext = ctx.content()
                Box(modifier = ctx.modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    AppRootView().Compose(context = contentContext)
                }
            }
        }
    }
}
