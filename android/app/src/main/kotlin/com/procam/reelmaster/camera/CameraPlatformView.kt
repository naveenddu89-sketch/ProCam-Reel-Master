package com.procam.reelmaster.camera

import android.content.Context
import android.view.View
import android.view.ViewGroup
import androidx.camera.view.PreviewView
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * Hosts a single PreviewView inside Flutter.
 * COMPATIBLE mode = TextureView, which composites correctly under Flutter's
 * grid/teleprompter overlays on every device (no SurfaceView z-order bugs).
 */
class CameraPlatformView(
    context: Context,
    private val engine: CameraEngine,
) : PlatformView {
    private val view = PreviewView(context).apply {
        layoutParams = ViewGroup.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT,
        )
        implementationMode = PreviewView.ImplementationMode.COMPATIBLE
        scaleType = PreviewView.ScaleType.FILL_CENTER
    }

    init {
        engine.attachPreview(view)
    }

    override fun getView(): View = view

    override fun dispose() {
        engine.detachPreview(view)
    }
}

class CameraPlatformViewFactory(
    private val engine: CameraEngine,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
        CameraPlatformView(context, engine)
}
