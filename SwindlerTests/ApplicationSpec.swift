import Quick
import Nimble

@testable import Swindler
import AXSwift
import PromiseKit

class OSXApplicationDelegateInitializeSpec: QuickSpec {
  override func spec() {

    var notifier: TestNotifier!
    beforeEach {
      notifier = TestNotifier()
    }

    describe("initialize") {
      var appElement: TestApplicationElement!
      beforeEach {
        appElement = TestApplicationElement()
      }

      typealias AppDelegate = OSXApplicationDelegate<TestUIElement, TestApplicationElement, FakeObserver>

      context("when the application UIElement is invalid") {
        it("resolves to an error") { () -> Promise<Void> in
          appElement.throwInvalid = true
          let promise =
            AppDelegate.initialize(axElement: appElement, stateDelegate: StubStateDelegate(), notifier: notifier)
          return expectToFail(promise)
        }
      }

      context("when the application is missing the Windows attribute") {
        it("resolves to an error") { () -> Promise<Void> in
          appElement.attrs[.Windows] = nil
          let promise =
            AppDelegate.initialize(axElement: appElement, stateDelegate: StubStateDelegate(), notifier: notifier)
          return expectToFail(promise)
        }
      }

      context("when the application is missing a required property attribute") {
        it("resolves to an error") { () -> Promise<Void> in
          appElement.attrs[.Hidden] = nil
          let promise =
            AppDelegate.initialize(axElement: appElement, stateDelegate: StubStateDelegate(), notifier: notifier)
          return expectToFail(promise)
        }
      }

      context("when the application is missing an optional property attribute") {
        it("succeeds") { () -> Promise<Void> in
          appElement.attrs[.MainWindow] = nil
          let promise =
            AppDelegate.initialize(axElement: appElement, stateDelegate: StubStateDelegate(), notifier: notifier)
          return expectToSucceed(promise)
        }
      }

      it("doesn't leak") {
        weak var appDelegate: AppDelegate?
        waitUntil { done in
          AppDelegate.initialize(axElement: appElement, stateDelegate: StubStateDelegate(), notifier: notifier)
            .then { delegate -> () in
              appDelegate = delegate
              done()
            }.always {}
        }
        expect(appDelegate).to(beNil())
      }

      it("doesn't leak the notifier") {
        weak var notifier: TestNotifier?
        var appDelegate: AppDelegate?
        waitUntil { done in
          let n = TestNotifier()
          notifier = n
          AppDelegate.initialize(axElement: appElement, stateDelegate: StubStateDelegate(), notifier: n)
            .then { delegate -> () in
              appDelegate = delegate
              done()
            }.always {}
        }
        expect(appDelegate).toNot(beNil())
        expect(notifier).to(beNil())
      }

      context("when there is a window") {
        it("doesn't leak memory") {
          let windowElement = TestWindowElement(forApp: appElement)
          appElement.windows.append(windowElement)

          weak var appDelegate: AppDelegate?
          waitUntil { done in
            AppDelegate.initialize(axElement: appElement, stateDelegate: StubStateDelegate(), notifier: notifier)
              .then { delegate -> () in
                expect(delegate.knownWindows).to(haveCount(1))
                appDelegate = delegate
                done()
              }.always {}
          }
          expect(appDelegate).to(beNil())
        }
      }

      context("when the observer throws an error during initialization") {
        final class ThrowingInitObserver: FakeObserver {
          required init(processID: pid_t, callback: @escaping Callback) throws {
            try super.init(processID: processID, callback: callback)
            throw AXError.failure
          }
        }

        it("resolves to an error") { () -> Promise<Void> in
          let promise = OSXApplicationDelegate<TestUIElement, TestApplicationElement, ThrowingInitObserver>
            .initialize(axElement: appElement, stateDelegate: StubStateDelegate(), notifier: notifier)
          return expectToFail(promise)
        }

      }

      context("when the observer throws an error during adding notifications") {
        class ThrowingAddObserver: FakeObserver {
          override func addNotification(_ notification: AXNotification, forElement element: TestUIElement) throws {
            throw AXError.failure
          }
        }

        it("resolves to an error") { () -> Promise<Void> in
          let promise = OSXApplicationDelegate<TestUIElement, TestApplicationElement, ThrowingAddObserver>
            .initialize(axElement: appElement, stateDelegate: StubStateDelegate(), notifier: notifier)
          return expectToFail(promise)
        }

      }

    }

  }
}

class OSXApplicationDelegateNotificationSpec: QuickSpec {
  override func spec() {

    describe("AXUIElement notifications") {
      var appElement: AdversaryApplicationElement!
      var notifier: TestNotifier!
      beforeEach {
        appElement = AdversaryApplicationElement()
        notifier = TestNotifier()
      }
      beforeEach { AdversaryObserver.reset() }

      // Have to persist this to create an Application or Window, which is needed for parts of this test
      // and for the AppDelegate to emit events (see #3).
      var stubStateDelegate: StateDelegate!

      typealias AppDelegate = OSXApplicationDelegate<TestUIElement, AdversaryApplicationElement, AdversaryObserver>
      func initializeApp() -> AppDelegate {
        // Initializing the app synchronously avoids problems with intermittent failures caused by
        // Quick/Nimble and simplifies tests.
        var appDelegate: AppDelegate?
        waitUntil { done in
          stubStateDelegate = StubStateDelegate()
          AppDelegate.initialize(axElement: appElement, stateDelegate: stubStateDelegate, notifier: notifier)
            .then { appDel -> () in
              appDelegate = appDel
              done()
            }.always {}
        }
        return appDelegate!
      }

      context("when a property value changes right before observing it") {

        context("for a regular property") {
          it("is read correctly") {
            appElement.attrs[.Hidden] = false

            AdversaryObserver.onAddNotification(.ApplicationHidden) { _ in
              appElement.attrs[.Hidden] = true
            }

            let appDelegate = initializeApp()
            expect(appDelegate.isHidden.value).toEventually(beTrue())
          }
        }

        context("for an object property") {
          it("is read correctly") {
            let windowElement = TestWindowElement(forApp: appElement)
            appElement.windows.append(windowElement)
            windowElement.attrs[.Main]    = false
            appElement.attrs[.MainWindow] = nil

            AdversaryObserver.onAddNotification(.MainWindowChanged) { observer in
              windowElement.attrs[.Main]    = true
              appElement.attrs[.MainWindow] = windowElement
            }

            let appDelegate = initializeApp()
            expect(appDelegate.mainWindow.value).toEventuallyNot(beNil())
          }
        }

      }

      context("when a property value changes right after observing it") {
        // The difference between a property changing before or after observing is simply whether
        // an event is emitted or not.

        context("for a regular property") {
          it("is updated correctly") {
            appElement.attrs[.Hidden] = false

            AdversaryObserver.onAddNotification(.ApplicationHidden) { observer in
              appElement.attrs[.Hidden] = true
              observer.emit(.ApplicationHidden, forElement: appElement)
            }

            let appDelegate = initializeApp()
            expect(appDelegate.isHidden.value).toEventually(beTrue())
          }
        }

        context("for an object property") {
          it("is updated correctly") {
            let windowElement = TestWindowElement(forApp: appElement)
            appElement.windows.append(windowElement)
            windowElement.attrs[.Main]    = false
            appElement.attrs[.MainWindow] = nil

            AdversaryObserver.onAddNotification(.MainWindowChanged) { observer in
              windowElement.attrs[.Main]    = true
              appElement.attrs[.MainWindow] = windowElement
              observer.emit(.MainWindowChanged, forElement: windowElement)
            }

            let appDelegate = initializeApp()
            expect(appDelegate.mainWindow.value).toEventuallyNot(beNil())
          }
        }

      }

      context("when a property value changes right after reading it") {

        context("for a regular property") {
          it("is updated correctly") {
            appElement.attrs[.Hidden] = false

            var observer: AdversaryObserver?
            AdversaryObserver.onAddNotification(.ApplicationHidden) { obs in
              observer = obs
            }
            appElement.onFirstAttributeRead(.Hidden) { _ in
              appElement.attrs[.Hidden] = true
              observer?.emit(.ApplicationHidden, forElement: appElement)
            }

            let appDelegate = initializeApp()
            expect(appDelegate.isHidden.value).toEventually(beTrue())
          }
        }

        context("for an object property") {
          it("is updated correctly") {
            let windowElement = TestWindowElement(forApp: appElement)
            appElement.windows.append(windowElement)
            windowElement.attrs[.Main]    = false
            appElement.attrs[.MainWindow] = nil

            var observer: AdversaryObserver?
            AdversaryObserver.onAddNotification(.MainWindowChanged) { obs in
              observer = obs
            }
            appElement.onFirstAttributeRead(.MainWindow) { _ in
              windowElement.attrs[.Main]    = true
              appElement.attrs[.MainWindow] = windowElement
              observer?.emit(.MainWindowChanged, forElement: appElement)
            }

            let appDelegate = initializeApp()
            expect(appDelegate.mainWindow.value).toEventuallyNot(beNil())
          }
        }

      }

      describe("knownWindows") {
        var windowElement: TestWindowElement!
        var observer: AdversaryObserver?
        beforeEach {
          windowElement = TestWindowElement(forApp: appElement)
          AdversaryObserver.onAddNotification(.WindowCreated) { observer = $0 }
        }

        // Currently I don't have a way of making these race condition tests deterministic. They
        // rely on 100ms sleeps. This isn't ideal, but they fail consistently for me before the fix.

        context("when a window is created right after reading the windows attribute, but the event comes before the read returns") {
          it("doesn't remove the window") {
            appElement.onFirstAttributeRead(.Windows, onMainThread: false) { _ in
              performOnMainThread {
                appElement.windows.append(windowElement)
                observer?.emit(.WindowCreated, forElement: windowElement)
              }

              // Wait for event to be processed on main thread.
              Thread.sleep(forTimeInterval: 0.1)

              // Will return no windows.
            }

            let appDelegate = initializeApp()
            expect(appDelegate.knownWindows).toEventually(haveCount(1))
          }
        }

        context("when a window is created right before reading the windows attribute and the event comes after reading") {
          it("doesn't create more than one window") {
            appElement.windows.append(windowElement)  // before read

            let appDelegate = initializeApp()
            waitUntil(appDelegate.knownWindows.count == 1)
            observer?.emit(.WindowCreated, forElement: windowElement)

            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

            expect(appDelegate.knownWindows).to(haveCount(1))
          }
        }

      }
    }

  }
}

class OSXApplicationDelegateSpec: QuickSpec {
  override func spec() {

    var appDelegate: OSXApplicationDelegate<TestUIElement, AdversaryApplicationElement, FakeObserver>!
    var appElement: AdversaryApplicationElement!
    var notifier: TestNotifier!
    var observer: FakeObserver!

    // Have to persist this to create an Application or Window, which is needed for parts of this test
    // and for the AppDelegate to emit events (see #3).
    var stubStateDelegate: StateDelegate!

    func initializeApp() {
      waitUntil { done in
        stubStateDelegate = StubStateDelegate()
        OSXApplicationDelegate<TestUIElement, AdversaryApplicationElement, FakeObserver>.initialize(
          axElement: appElement, stateDelegate: stubStateDelegate, notifier: notifier
        ).then { applicationDelegate -> () in
          appDelegate = applicationDelegate
          observer = appDelegate.observer
          done()
        }.always {}
      }
    }

    beforeEach {
      notifier = TestNotifier()
      appElement = AdversaryApplicationElement()
      initializeApp()
    }

    @discardableResult
    func createWindow(
      emitEvent: Bool = true,
      windowElement element: TestWindowElement? = nil
    ) -> TestWindowElement {
      let windowElement = element ?? TestWindowElement(forApp: appElement)
      appElement.windows.append(windowElement)
      if emitEvent { observer.emit(.WindowCreated, forElement: windowElement) }
      return windowElement
    }

    func getWindowElement(_ windowDelegate: WindowDelegate?) -> TestUIElement? {
      typealias WinDelegate = OSXWindowDelegate<TestUIElement, AdversaryApplicationElement, FakeObserver>
      return (windowDelegate as! WinDelegate?)?.axElement
    }
    func getWindowElementForWindow(_ window: Window?) -> TestUIElement? {
      return getWindowElement(window?.delegate)
    }

    describe("knownWindows") {
      func getWindowElements(_ windows: [WindowDelegate]) -> [TestUIElement] {
        return windows.map({ getWindowElement($0)! })
      }

      context("right after initialization") {

        context("when there are no windows") {
          it("is empty") {
            expect(appDelegate.knownWindows).to(beEmpty())
          }
        }

        context("when there are multiple windows") {
          it("contains all windows") {
            let windowElement1 = createWindow(emitEvent: false)
            let windowElement2 = createWindow(emitEvent: false)
            initializeApp()

            expect(getWindowElements(appDelegate.knownWindows)).to(contain(windowElement1, windowElement2))
          }
        }

        context("when one window is invalid") {
          it("contains only the valid windows") {
            let validWindowElement   = createWindow(emitEvent: false)
            let invalidWindowElement = createWindow(emitEvent: false)
            invalidWindowElement.throwInvalid = true
            initializeApp()

            expect(getWindowElements(appDelegate.knownWindows)).to(contain(validWindowElement))
            expect(getWindowElements(appDelegate.knownWindows)).toNot(contain(invalidWindowElement))
          }
        }

      }

      context("when a new window is created") {

        it("adds the window") {
          let windowElement = createWindow()
          expect(getWindowElements(appDelegate.knownWindows)).toEventually(contain(windowElement))
        }

        it("does not remove other windows") {
          let windowElement1 = createWindow(emitEvent: false)
          initializeApp()
          let windowElement2 = createWindow()

          waitUntil(getWindowElements(appDelegate.knownWindows).contains(windowElement2))
          expect(getWindowElements(appDelegate.knownWindows)).to(contain(windowElement1))
        }

      }

      context("when a window is destroyed") {

        it("removes the window") {
          let windowElement = createWindow(emitEvent: false)
          initializeApp()
          observer.emit(.UIElementDestroyed, forElement: windowElement)

          expect(getWindowElements(appDelegate.knownWindows)).toEventuallyNot(contain(windowElement))
        }

        it("does not remove other windows") {
          let windowElement1 = createWindow(emitEvent: false)
          let windowElement2 = createWindow(emitEvent: false)
          initializeApp()
          observer.emit(.UIElementDestroyed, forElement: windowElement1)

          waitUntil(!getWindowElements(appDelegate.knownWindows).contains(windowElement1))
          expect(getWindowElements(appDelegate.knownWindows)).to(contain(windowElement2))
        }

      }
    }

    // mainWindow is quite a bit more complicated than other properties, so we explicitly test it
    // here.
    describe("mainWindow") {

      context("when there is no initial main window") {
        it("initially equals nil") {
          expect(appElement.attrs[.MainWindow]).to(beNil())
          expect(appDelegate.mainWindow.value).to(beNil())
        }
      }

      context("when there is an initial main window") {
        it("equals the main window") {
          let windowElement = createWindow(emitEvent: false)
          windowElement.attrs[.Main] = true
          appElement.attrs[.MainWindow] = windowElement
          initializeApp()

          expect(getWindowElementForWindow(appDelegate.mainWindow.value)).to(equal(windowElement))
        }
      }

      context("when a window becomes main") {
        var windowElement: TestWindowElement!
        beforeEach {
          windowElement = createWindow()
          windowElement.attrs[.Main] = true
          appElement.attrs[.MainWindow] = windowElement
          observer.emit(.MainWindowChanged, forElement: windowElement)
        }

        it("updates the value") {
          expect(getWindowElementForWindow(appDelegate.mainWindow.value)).toEventually(equal(windowElement))
        }

        it("emits an ApplicationMainWindowChangedEvent with correct values") {
          if let event = notifier.expectEvent(ApplicationMainWindowChangedEvent.self) {
            expect(event.application.delegate.equalTo(appDelegate)).to(beTrue())
            expect(event.external).to(beTrue())
            expect(event.oldValue).to(beNil())
            expect(getWindowElementForWindow(event.newValue)).to(equal(windowElement))
          }
        }

        // TODO: timeout on reading .Role
      }

      context("when a new window becomes the main window") {
        it("updates the value") {
          let windowElement = createWindow(emitEvent: false)
          windowElement.attrs[.Main] = true
          appElement.attrs[.MainWindow] = windowElement

          // Usually we get the MWC notification before WindowCreated. Simply doing dispatch_async
          // to wait for WindowCreated doesn't always work, so we defeat that here.
          observer.emit(.MainWindowChanged, forElement: windowElement)
          DispatchQueue.main.async() {
            DispatchQueue.main.async() {
              observer.emit(.WindowCreated, forElement: windowElement)
            }
          }

          expect(getWindowElementForWindow(appDelegate.mainWindow.value)).toEventually(equal(windowElement))
        }
      }

      context("when the application switches to having no main window") {
        var mainWindowElement: TestWindowElement!
        beforeEach {
          mainWindowElement = createWindow()
          mainWindowElement.attrs[.Main] = true
          appElement.attrs[.MainWindow] = mainWindowElement
          initializeApp()
        }

        it("becomes nil") {
          appElement.attrs[.MainWindow] = nil
          observer.emit(.MainWindowChanged, forElement: appElement)
          expect(appDelegate.mainWindow.value).toEventually(beNil())
        }

        context("because the main window closes") {
          it("becomes nil") {
            // TODO: what if it's just destroyed?
            appElement.attrs[.MainWindow] = nil
            observer.emit(.UIElementDestroyed, forElement: mainWindowElement)
            observer.emit(.MainWindowChanged, forElement: appElement)
            expect(appDelegate.mainWindow.value).toEventually(beNil())
          }
        }

        context("and the passed application element doesn't equal our stored application element") {
          // Because shit happens. Finder does this.
          it("becomes nil") {
            let otherAppElement = TestUIElement()
            otherAppElement.processID = appElement.processID
            otherAppElement.attrs = appElement.attrs
            assert(appElement != otherAppElement)

            appElement.attrs[.MainWindow] = nil
            observer.doEmit(.MainWindowChanged, watchedElement: appElement, passedElement: otherAppElement)
            expect(appDelegate.mainWindow.value).toEventually(beNil())
          }
        }

        // TODO: timeout on reading .Role
      }

      context("when a window is assigned") {

        var windowElement: TestWindowElement!
        var windowDelegate: WindowDelegate!
        var setPromise: Promise<Window?>!
        func createAndSetMainWindow(_ element: TestWindowElement) {
          windowElement = element
          createWindow(windowElement: element)
          waitUntil(appDelegate.knownWindows.count == 1)
          windowDelegate = appDelegate.knownWindows.first!
          let window = Window(delegate: windowDelegate)!
          setPromise = appDelegate.mainWindow.set(window)
        }

        context("when the app complies") {
          beforeEach {
            createAndSetMainWindow(TestWindowElement(forApp: appElement))
          }

          it("changes the main window") {
            expect(windowElement.attrs[.Main] as! Bool?).toEventually(beTrue())
          }

          it("returns the new main window in the promise") { () -> Promise<Void> in
            return setPromise.then { newMainWindow in
              expect(newMainWindow?.delegate.equalTo(windowDelegate)).to(beTrue())
            }
          }

        }

        context("when the app refuses to make the window main") {
          class MyWindowElement: TestWindowElement {
            override func setAttribute(_ attribute: Attribute, value: Any) throws {
              if attribute == .Main { return }
              else { try super.setAttribute(attribute, value: value) }
            }
          }
          beforeEach {
            createAndSetMainWindow(MyWindowElement(forApp: appElement))
          }

          it("returns the old value in the promise") { () -> Promise<Void> in
            return setPromise.then { newMainWindow in
              expect(newMainWindow).to(beNil())
            }
          }

        }

      }

      context("when a new window becomes main then closes before reading the attribute") {
        it("updates the value correctly") {
          let lastingWindowElement      = createWindow(emitEvent: false)
          appElement.attrs[.MainWindow] = nil
          initializeApp()

          let closingWindowElement = createWindow(emitEvent: false)
          closingWindowElement.throwInvalid = true

          appElement.windows = appElement.windows.filter({ $0 != closingWindowElement })
          appElement.attrs[.MainWindow]     = lastingWindowElement
          lastingWindowElement.attrs[.Main] = true

          observer.emit(.MainWindowChanged, forElement: closingWindowElement)
          observer.emit(.WindowCreated, forElement: closingWindowElement)
          observer.emit(.UIElementDestroyed, forElement: closingWindowElement)
          observer.emit(.MainWindowChanged, forElement: lastingWindowElement)

          expect(getWindowElementForWindow(appDelegate.mainWindow.value)).toEventually(equal(lastingWindowElement))

          // It should only emit the event for lastingWindowElement.
          expect(notifier.getEventsOfType(ApplicationMainWindowChangedEvent.self)).toEventually(haveCount(1))
          if let event = notifier.getEventOfType(ApplicationMainWindowChangedEvent.self) {
            expect(getWindowElementForWindow(event.newValue)).to(equal(lastingWindowElement))
          }
        }
      }

      context("when a new window becomes main then closes after reading the attribute") {
        it("updates the value correctly") {
          let lastingWindowElement      = createWindow(emitEvent: false)
          appElement.attrs[.MainWindow] = nil
          initializeApp()

          let closingWindowElement = createWindow(emitEvent: false)
          closingWindowElement.attrs[.Main] = true
          appElement.attrs[.MainWindow]     = closingWindowElement

          appElement.onFirstAttributeRead(.MainWindow) { _ in
            appElement.windows = appElement.windows.filter({ $0 != closingWindowElement })
            appElement.attrs[.MainWindow]     = lastingWindowElement
            lastingWindowElement.attrs[.Main] = true
            observer.emit(.UIElementDestroyed, forElement: closingWindowElement)
            observer.emit(.MainWindowChanged, forElement: lastingWindowElement)
          }

          observer.emit(.MainWindowChanged, forElement: closingWindowElement)
          observer.emit(.WindowCreated, forElement: closingWindowElement)

          expect(getWindowElementForWindow(appDelegate.mainWindow.value)).toEventually(equal(lastingWindowElement))

          // It should only emit the event for lastingWindowElement.
          expect(notifier.getEventsOfType(ApplicationMainWindowChangedEvent.self)).toEventually(haveCount(1))
          if let event = notifier.getEventOfType(ApplicationMainWindowChangedEvent.self) {
            expect(getWindowElementForWindow(event.newValue)).to(equal(lastingWindowElement))
          }
        }
      }

    }

    describe("focusedWindow") {

      context("when there is no initial focused window") {
        it("equals nil") {
          expect(appElement.attrs[.FocusedWindow]).to(beNil())
          expect(appDelegate.focusedWindow.value).to(beNil())
        }
      }

      context("when there is an initial focused window") {
        it("equals the main window") {
          let windowElement = createWindow(emitEvent: false)
          windowElement.attrs[.Focused] = true
          appElement.attrs[.FocusedWindow] = windowElement
          initializeApp()

          expect(getWindowElementForWindow(appDelegate.focusedWindow.value)).to(equal(windowElement))
        }
      }

      context("when a window becomes focused") {
        var windowElement: TestWindowElement!
        beforeEach {
          windowElement = createWindow()
          windowElement.attrs[.Focused] = true
          appElement.attrs[.FocusedWindow] = windowElement
          observer.emit(.FocusedWindowChanged, forElement: windowElement)
        }

        it("updates the value") {
          expect(getWindowElementForWindow(appDelegate.focusedWindow.value)).toEventually(equal(windowElement))
        }

         it("emits an ApplicationFocusedWindowChangedEvent with correct values") {
           if let event = notifier.expectEvent(ApplicationFocusedWindowChangedEvent.self) {
             expect(event.application.delegate.equalTo(appDelegate)).to(beTrue())
             expect(event.external).to(beTrue())
             expect(event.oldValue).to(beNil())
             expect(getWindowElementForWindow(event.newValue)).to(equal(windowElement))
           }
         }

      }
    }

    describe("isHidden") {
      context("when an application hides") {
        beforeEach {
          appElement.attrs[.Hidden] = true
          observer.emit(.ApplicationHidden, forElement: appElement)
        }

        it("updates") {
          expect(appDelegate.isHidden.value).toEventually(beTrue())
        }

        it("emits ApplicationIsHiddenChangedEvent") {
          notifier.expectEvent(ApplicationIsHiddenChangedEvent.self)
        }

      }

      context("when an application unhides") {
        beforeEach {
          appElement.attrs[.Hidden] = true
          initializeApp()
          appElement.attrs[.Hidden] = false
          observer.emit(.ApplicationShown, forElement: appElement)
        }

        it("updates") {
          expect(appDelegate.isHidden.value).toEventually(beFalse())
        }

        it("emits ApplicationIsHiddenChangedEvent") {
          notifier.expectEvent(ApplicationIsHiddenChangedEvent.self)
        }

      }
    }

    describe("equalTo") {

      it("returns true for identical app delegates") {
        expect(appDelegate.equalTo(appDelegate)).to(beTrue())
      }

      it("returns false for different app delegates") { () -> Promise<Void> in
        let otherAppElement = AdversaryApplicationElement()
        return OSXApplicationDelegate<TestUIElement, AdversaryApplicationElement, FakeObserver>
          .initialize(axElement: otherAppElement, stateDelegate: StubStateDelegate(), notifier: notifier)
          .then { otherAppDelegate -> () in
            expect(appDelegate.equalTo(otherAppDelegate)).to(beFalse())
          }
      }

    }

    context("when a window is created") {
      var windowElement: TestWindowElement!
      beforeEach {
        windowElement = createWindow()
      }

      it("watches for events on the window") {
        notifier.waitUntilEvent(WindowCreatedEvent.self)
        expect(observer.watchedElements[windowElement]).toNot(beNil())
      }

      it("emits WindowCreatedEvent") {
        if let event = notifier.expectEvent(WindowCreatedEvent.self) {
          expect(getWindowElementForWindow(event.window)).to(equal(windowElement))
        }
      }

      it("marks the WindowCreatedEvent as external") {
        if let event = notifier.waitUntilEvent(WindowCreatedEvent.self) {
          expect(event.external).to(beTrue())
        }
      }

    }

    context("when a window is destroyed") {
      var windowElement: TestWindowElement!
      beforeEach {
        windowElement = createWindow()
        notifier.waitUntilEvent(WindowCreatedEvent.self)
        observer.emit(.UIElementDestroyed, forElement: windowElement)
      }

      it("emits WindowDestroyedEvent") {
        if let event = notifier.expectEvent(WindowDestroyedEvent.self) {
          expect(getWindowElementForWindow(event.window)).to(equal(windowElement))
        }
      }

      it("marks the WindowDestroyedEvent as external") {
        if let event = notifier.waitUntilEvent(WindowDestroyedEvent.self) {
          expect(event.external).to(beTrue())
        }
      }

    }

  }
}
