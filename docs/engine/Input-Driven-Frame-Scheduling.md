# Design Document: Input-Driven Low-Latency Frame Scheduling

## 1. Executive Summary & Problem Statement

Across all supported Flutter embedders—**Android, iOS, macOS, Windows, and Linux**—visual updates initiated by user input suffer from a universal **one-frame scheduling latency**. 

This latency gap arises from a fundamental architectural decoupling between **input event delivery** and **frame scheduling**:
1. **Asynchronous Input Routing**: Operating system input events (e.g., `UITouch` on iOS, `MotionEvent` on Android, Win32 mouse messages on Windows) arrive on the embedder's platform thread/run-loop. The embedder packages these events into a `flutter::PointerDataPacket` and dispatches them asynchronously across the C++/JNI boundary to the Dart framework's event loop.
2. **Deferred Vsync Alignment**: Once Dart consumes the pointer packet, processes the gesture, and invalidates visual state (e.g., via `setState()`), it invokes `scheduleFrame()`. This request lands in the C++ engine's `Animator` and delegates to the platform's `VsyncWaiter`.
3. **The Vsync Bottleneck**: Every platform's `VsyncWaiter` implementation deliberately defers triggering the frame build to align with the **upcoming** vsync boundary/timer tick:
   - **iOS**: Unpauses `CADisplayLink` and waits for the next `onDisplayLink:` hardware callback.
   - **Android**: Delegates to `Choreographer.postFrameCallback()`, which strictly executes at the next hardware vsync pulse.
   - **macOS**: Delegates to `CVDisplayLink`, queuing a timed execution block to align with the next frame start phase.
   - **Windows/Linux**: Uses `VsyncWaiterFallback`, computing the next virtual 60Hz software tick boundary and posting a delayed task (`PostTaskForTime`).

Consequently, building the frame triggered by the touch/mouse event cannot begin immediately upon input ingestion. It is deferred until the subsequent vsync tick, resulting in an unnecessary extra frame of input-to-glass latency.

---

## 2. Proposed Architectural Resolution

Rather than introducing dirty timing hacks or artificial run-loop pumping inside each individual platform embedder, we elevate **Proactive Edge-Triggered Wakes** to a first-class concept inside the central C++ **`Animator`** pipeline.

### Core Principles
* **Embedder Simplicity**: The platform embedders act strictly as lightweight messengers. Their only responsibility is to signal an explicit input intent (`"High-priority input event arrived"`) alongside dispatching pointer packets.
* **Centralized State Routing**: The `Animator` acts as the intelligent routing controller. Upon receiving an input notification, it evaluates its internal state machine:
  * **If the Framework is Idle**: It proactively requests a pipeline continuation and fires an immediate frame build on the UI thread, bypassing the hardware vsync wait to eliminate the initial input latency.
  * **If an Animation is Active**: It recognizes that frames are already actively building or scheduled. It silently absorbs the input notification, avoiding duplicate work while allowing the hardware vsync cadence to preserve perfectly smooth frame pacing.
* **Preserving Timing Integrity**: The `Animator` drives the early frame build while continuing to request and pass genuine hardware target presentation timestamps (`targetTime`) to the `FrameTimingsRecorder`, maintaining flawless metrics reporting and smooth animation interpolation.

---

## 3. Embedder API Changes (`embedder.h`)

To expose this functionality cleanly to custom embedders and internal platform shells, we extend the public C C++ Embedder API.

### `shell/platform/embedder/embedder.h`

```c
/**
 * @brief Signals to the Flutter engine that a high-priority input event (such as a touch down
 *        or drag) has arrived.
 *
 * If the engine's rendering pipeline is currently idle, this proactive notification instructs
 * the engine to immediately begin scheduling and building a frame on the UI thread, bypassing
 * standard hardware vsync wait intervals to minimize initial input latency.
 *
 * If a frame is already actively being built or scheduled, this call is safely absorbed with
 * no side effects.
 *
 * @param engine The valid Flutter engine instance.
 * @return FLUTTER_RESULT_SUCCESS if the notification was successfully routed to the Animator.
 */
FLUTTER_EXPORT
FlutterResult FlutterEngineNotifyInputEvent(FlutterEngine engine);
```

*Backward Compatibility*: Existing embedders that do not call `FlutterEngineNotifyInputEvent` will continue to function perfectly under standard vsync-driven scheduling semantics.

### Design Naming Discussion
While the embedder API already exposes **`FlutterEngineScheduleFrame`**, that function specifically delegates to standard vsync-aligned scheduling. 
* Naming the new entrypoint **`FlutterEngineNotifyInputEvent`** provides excellent semantic clarity: it explicitly conveys **intent** rather than direct execution control. The embedder simply reports high-priority input activity, leaving the central `Animator` state machine responsible for deciding whether to trigger an immediate edge-triggered wake or absorb the request silently.
* Reusing or overloading `ScheduleFrame` / `RequestFrame` shifts the mental model toward manual frame scheduling, which risks confusing embedder authors and breaking standard frame pacing invariants if misused outside of input delivery contexts.

---

## 4. Animator API Changes (`animator.h`)

We introduce explicit input-signaling entrypoints to the core `Animator` interface.

### `shell/common/animator.h`

```cpp
namespace flutter {

class Animator final {
 public:
  // Existing public methods...
  void RequestFrame(bool regenerate_layer_trees = true);
  void Render(int64_t view_id,
              std::unique_ptr<flutter::LayerTree> layer_tree,
              float device_pixel_ratio);

  //--------------------------------------------------------------------------
  /// @brief    Notifies the Animator that a high-priority input event has been
  ///           dispatched by the platform embedder.
  ///
  ///           If the pipeline is idle, this triggers an immediate proactive
  ///           frame build sequence.
  void NotifyInputEventPending();

 private:
  // Existing private methods...
  void BeginFrame(std::unique_ptr<FrameTimingsRecorder> frame_timings_recorder);
  void EndFrame();
  void AwaitVSync();

  // Proactively executes a frame build if the state machine allows it.
  void ScheduleInputDrivenFrame();

  bool input_event_pending_ = false;
};

}  // namespace flutter
```

---

## 5. Implementation Details (`vsync_waiter.cc` & `animator.cc`)

Inside `vsync_waiter.cc`, the immediate execution logic handles early frame firing safely while enforcing strict frame pacing throttling and timestamp monotonicity invariants:

### `shell/common/vsync_waiter.cc`

```cpp
namespace flutter {

void VsyncWaiter::FireImmediate() {
  auto now = fml::TimePoint::Now();
  // If we fired a frame callback very recently (e.g. within the last 8ms),
  // absorb this immediate request silently to prevent pumping frames faster
  // than the display refresh rate during fast input/dragging.
  if (now - last_fire_callback_time_ < fml::TimeDelta::FromMilliseconds(8)) {
    return;
  }
  auto target = now + fml::TimeDelta::FromSecondsF(1.0 / 60.0);
  FireCallback(now, target, true);
}

void VsyncWaiter::FireCallback(fml::TimePoint frame_start_time,
                               fml::TimePoint frame_target_time,
                               bool pause_secondary_tasks) {
  FML_DCHECK(fml::TimePoint::Now() >= frame_start_time);

  Callback callback;
  std::vector<fml::closure> secondary_callbacks;

  {
    std::scoped_lock lock(callback_mutex_);
    callback = std::move(callback_);
    for (auto& pair : secondary_callbacks_) {
      secondary_callbacks.push_back(std::move(pair.second));
    }
    secondary_callbacks_.clear();
  }

  if (!callback && secondary_callbacks.empty()) {
    return;
  }

  if (callback) {
    // Ensure target timestamps strictly increase to avoid clamping errors.
    if (last_frame_target_time_ > frame_target_time) {
      frame_target_time = last_frame_target_time_;
    }
    last_frame_target_time_ = frame_target_time;
    last_fire_callback_time_ = fml::TimePoint::Now();

    // Standard execution posting to UI thread...
  }
}

}  // namespace flutter
```

### `shell/common/animator.cc`

```cpp
namespace flutter {

void Animator::NotifyInputEventPending() {
  if (waiter_) {
    waiter_->FireImmediate();
  }
}

}  // namespace flutter
```

---

## 6. Patching Platform Embedders

Each platform embedder is patched to invoke the notification API during primary user interactions (e.g., touch down, drag, or mouse down).

### iOS (`FlutterViewController.mm`)
Inside `dispatchTouches:pointerDataChangeOverride:event:`, after dispatching the pointer packet:
```objc
[self.engine dispatchPointerDataPacket:std::move(packet)];

// Signal proactive wake for active interactions.
if (isUserInteracting && self.engine.enableEmbedderAPI) {
  self.engine.embedderAPI.NotifyInputEvent(self.engine.engineIdentifier);
} else if (isUserInteracting) {
  // Or via internal engine reference directly:
  self.engine.shell.GetEngine()->NotifyInputEventPending();
}
```

### Android (`AndroidTouchProcessor.java` / C++ JNI)
Extend `FlutterRenderer.java` with `notifyInputEvent()` routed over JNI to call `Engine::NotifyInputEventPending()`.
Inside `AndroidTouchProcessor.onTouchEvent()`:
```java
renderer.dispatchPointerDataPacket(packet, packet.position());
if (maskedAction == MotionEvent.ACTION_DOWN || maskedAction == MotionEvent.ACTION_MOVE) {
  renderer.notifyInputEvent();
}
```

### macOS (`FlutterViewController.mm`)
Inside `dispatchMouseEvent:phase:`:
```objc
[_engine sendPointerEvent:flutterEvent];
if (phase == kDown || phase == kMove || phase == kPanZoomStart || phase == kPanZoomUpdate) {
  _engine.shell.GetEngine()->NotifyInputEventPending();
}
```

### Windows (`flutter_windows.cc`)
Inside `FlutterWindowsView::SendPointerDataPacket`:
```cpp
engine_->DispatchPointerDataPacket(packet);
if (is_active_interaction) {
  engine_->NotifyInputEventPending();
}
```

### Linux (`flutter_linux.cc`)
Inside `fl_view_dispatch_pointer_event`:
```c
fl_engine_dispatch_pointer_data_packet(view->engine, packet);
if (event_phase == FL_POINTER_PHASE_DOWN || event_phase == FL_POINTER_PHASE_MOVE) {
  fl_engine_notify_input_event(view->engine);
}
```

---

## 7. Authoring Engine Tests

Robust testing is achieved using the C++ `ShellTest` framework to verify determinism and thread scheduling behaviors.

### `shell/common/animator_unittests.cc`

```cpp
TEST_F(AnimatorTest, ProactiveInputWakeTriggersImmediateFrame) {
  auto settings = CreateSettingsForTest();
  auto task_runners = GetTaskRunnersForTest();
  
  // Use a mock vsync waiter that NEVER automatically fires vsync ticks.
  auto mock_waiter = std::make_unique<MockVsyncWaiter>(task_runners);
  
  MockAnimatorDelegate delegate;
  auto animator = std::make_unique<Animator>(delegate, task_runners, std::move(mock_waiter));

  // Expect that calling NotifyInputEventPending proactively triggers BeginFrame.
  EXPECT_CALL(delegate, OnAnimatorBeginFrame(testing::_, testing::_)).Times(1);

  // Trigger the input notification.
  animator->NotifyInputEventPending();
  
  // Flush UI thread message loop to process tasks.
  fml::TaskRunner::RunNowAndFlushMessages(task_runners.GetUITaskRunner());
}

TEST_F(AnimatorTest, ProactiveInputWakeAbsorbedSilentlyIfFrameAlreadyScheduled) {
  auto settings = CreateSettingsForTest();
  auto task_runners = GetTaskRunnersForTest();
  auto mock_waiter = std::make_unique<MockVsyncWaiter>(task_runners);
  
  MockAnimatorDelegate delegate;
  auto animator = std::make_unique<Animator>(delegate, task_runners, std::move(mock_waiter));

  // Schedule a normal frame first.
  animator->RequestFrame();

  // Expect OnAnimatorBeginFrame fires exactly ONCE driven by standard vsync, not duplicated.
  EXPECT_CALL(delegate, OnAnimatorBeginFrame(testing::_, testing::_)).Times(1);

  // Trigger input notification while frame is pending.
  animator->NotifyInputEventPending();
  
  // Simulate the scheduled vsync arrival.
  mock_waiter->Fire();
  fml::TaskRunner::RunNowAndFlushMessages(task_runners.GetUITaskRunner());
}
```
