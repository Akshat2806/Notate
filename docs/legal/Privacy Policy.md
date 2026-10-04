# Notate Privacy Policy — Draft for Review

**Status: working draft, not ready to publish.** Replace every bracketed item and verify the descriptions against the release build, App Store privacy answers, vendors, and applicable law before publishing.

**Effective date:** [DATE]

This Privacy Policy explains how **[LEGAL OWNER NAME]** (“we,” “us,” or “our”) handles information when you use Notate on Apple devices. Privacy contact: **[PRIVACY OR SUPPORT EMAIL]**.

## At a glance

The current Notate app is designed to keep your notebooks and app preferences on your device. The app code reviewed for this draft uses local app storage, disables CloudKit, and contains no analytics, advertising, account, or purchase SDK. Notate does not currently send notebook content to a server. This description must be revisited before release if analytics, crash reporting, cloud sync, customer support uploads, payment integrations, or other network services are added.

## Information you create or choose

Notate stores the notebooks, pages, writing, drawings, imported documents and images, organization details, and preferences that you create or choose in the app. These are saved in Notate’s private app storage on your device. The app does not provide an account or its own cloud-sync service in the current version.

When you use Apple’s system document or photo pickers, you choose the file or image that Notate may import. The app receives the selected item and stores an app copy locally. Notate does not request broad access to your photo library in the current implementation.

## How information is used and shared

Locally stored information is used to provide the app’s note-taking, library, import, and export features. We do not sell, use for advertising, or share notebook contents with us or third parties through the current app implementation.

If you export or share a document, the export is prepared on your device and passed to the destination you select using Apple’s sharing or file interfaces. The destination’s provider may then process the file under its own terms and privacy practices. You control whether and where you share it.

Apple may process information under its own terms when you use Apple operating-system features, App Store services, or device backup. Notate does not control Apple’s processing. If device backups are enabled, app data may be included in a backup governed by your Apple settings and Apple’s policies.

## Purchases

**No purchase processing is present in the current app version reviewed for this draft.** If we introduce a paid feature, this section must be revised before release to identify the purchase processor and data flow. Purchases made through Apple In-App Purchase are processed by Apple. If a subscription-management provider such as RevenueCat is added, its role and any information it receives (which may include purchase/entitlement records and app or device identifiers) must be described accurately here and in App Store Connect privacy disclosures. Do not publish this paragraph unchanged after adding a payment SDK.

## Retention and deletion

Notate’s app-created content remains in the app’s local storage until you delete it in the app or remove the app and its data from your device. Notate has no account or server-side notebook store in the current version, so there is no Notate account deletion process. Deleted items may remain temporarily in the app’s trash or in device backups, according to the app’s behavior and your Apple backup settings. Confirm this wording against the shipped deletion and trash behavior.

You can remove imported or created content through the app’s available controls. You can remove app data by deleting Notate from your device; consult Apple’s documentation for how device backups are managed and deleted.

## Children

Notate is not directed to children under **[MINIMUM AGE / AGE POSITION]**. We do not knowingly collect personal information from children through the current app because the app has no account or server collection. Add the appropriate child-directed or age-specific disclosures if the intended audience or applicable law requires them.

## Security

Notate stores app content in its private app container and uses Apple platform storage protections. No method of storage or transmission is completely secure. Protect your device and its passcode, and consider the implications of device backups and exports.

## Changes to this policy

We may update this policy as Notate’s features or data practices change. We will change the effective date above and provide any notice required by law. The policy in effect for a release must match that release’s actual behavior.

## Contact

For privacy questions or requests, contact **[LEGAL OWNER NAME]** at **[PRIVACY OR SUPPORT EMAIL]**, or write to **[POSTAL ADDRESS, IF REQUIRED]**.

---

## Release verification notes (remove before publication)

- Confirm the compiled app and every embedded SDK have no analytics, diagnostics, advertising, attribution, or network collection not described here. Review the Xcode privacy report and SDK privacy manifests.
- Decide whether Apple device backups are in scope for the disclosure and align the wording with actual file-protection / backup-exclusion settings.
- Verify trash retention, permanent deletion, document export and photo/file import behavior against the release build.
- If adding RevenueCat or another purchase SDK, document exactly what it receives, purposes, retention, processors, and user choices; update App Store Connect privacy details and any required privacy manifest declarations.
- Publish this policy at a stable public HTTPS URL and enter it in App Store Connect. The in-app privacy screen must also link to or display the current policy.
- Reassess if cloud sync, accounts, feedback forms, crash reporting, support uploads, widgets, or other services are introduced.
