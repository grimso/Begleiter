//
//  BegleiterUITests.swift
//  BegleiterUITests
//
//  Created by Simon Grimm on 11.05.26.
//

import XCTest

final class BegleiterUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testExample() throws {
        let app = XCUIApplication()
        app.launch()
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    // MARK: - README screenshots
    //
    // Drives a fresh-install Begleiter through onboarding (via the
    // "Load demo data" shortcut), then captures every primary surface
    // with demo data populated. Each capture is attached to the test
    // result so it can be extracted from the .xcresult bundle.
    @MainActor
    func testCaptureReadmeScreenshots() throws {
        let app = XCUIApplication()
        app.launch()

        // 1. Onboarding — capture before we load demo data so the README
        //    can show the first-run experience.
        let loadDemo = app.buttons["Load demo data"].firstMatch
        if loadDemo.waitForExistence(timeout: 8) {
            attachScreenshot(name: "08-onboarding")
            loadDemo.tap()
            // Confirm sheet (second "Load demo data" button)
            let confirm = app.buttons.matching(identifier: "Load demo data").element(boundBy: 1)
            if confirm.waitForExistence(timeout: 3) {
                confirm.tap()
            }
            // Wait for home to appear after demo load
            _ = app.tabBars.firstMatch.waitForExistence(timeout: 8)
        }

        // 2. Home tab
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 8))
        tabs.buttons.element(boundBy: 0).tap()
        sleep(1)
        attachScreenshot(name: "01-home")

        // 3. Journal tab (now populated with 10 entries)
        tabs.buttons.element(boundBy: 1).tap()
        sleep(1)
        attachScreenshot(name: "02-timeline")

        // 4. Open a single journal entry detail
        let firstEntry = app.scrollViews.descendants(matching: .button).element(boundBy: 0)
        if firstEntry.waitForExistence(timeout: 3) {
            firstEntry.tap()
            sleep(1)
            attachScreenshot(name: "04-entry-detail")
            // Pop back
            let back = app.navigationBars.buttons.element(boundBy: 0)
            if back.exists { back.tap(); sleep(1) }
        }

        // 5. Insights tab — should now show WBC/ANC/PLT/HB trend charts
        tabs.buttons.element(boundBy: 2).tap()
        sleep(2)
        attachScreenshot(name: "03-insights")

        // 6. Back to home and tap Lab results tile -> lab plot composer
        tabs.buttons.element(boundBy: 0).tap()
        sleep(1)
        let labsCard = app.buttons["Lab results"].firstMatch
        if labsCard.waitForExistence(timeout: 3) {
            labsCard.tap()
            sleep(2)
            attachScreenshot(name: "05-labs")
            let back = app.navigationBars.buttons.element(boundBy: 0)
            if back.exists { back.tap(); sleep(1) }
        }

        // 7. Profile tab — landing
        tabs.buttons.element(boundBy: 3).tap()
        sleep(1)
        attachScreenshot(name: "06-profile")

        // 8. Profile -> Development. The row is a SwiftUI List cell —
        //    use the staticText to find it and tap the surrounding cell.
        let developmentText = app.staticTexts["Development"].firstMatch
        if developmentText.waitForExistence(timeout: 3) {
            // Tap directly on the static text — SwiftUI list rows are
            // hittable via their content.
            developmentText.tap()
            sleep(2)
            attachScreenshot(name: "07-settings")
        }
    }

    // MARK: - Helpers

    @MainActor
    private func attachScreenshot(name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
