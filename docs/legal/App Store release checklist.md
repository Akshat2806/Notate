# App Store legal and privacy release checklist

This checklist is based on the current Notate source review and Apple documentation checked on 4 October 2026. It is not a legal opinion or a guarantee of App Review approval.

## Current code observations

- Notebook/library data and preferences are stored locally. CloudKit is explicitly disabled in the SwiftData configuration.
- The project search found no app networking, analytics, advertising, account, or purchase SDK integration.
- The app imports user-selected photos/files and offers document export/share flows.
- Settings has an in-app Privacy page, but its loader expects `Privacy.md` in the app bundle and no such file is currently present. The page therefore displays its unavailable fallback.
- A working tree change already exists in `Notate/Persistence/LibraryRepository.swift`; it was not changed as part of this draft.

## Before submission

- Complete all bracketed placeholders in the [Privacy Policy](Privacy%20Policy.md) and [Terms of Use](Terms%20of%20Use.md), then have counsel check jurisdiction-specific language.
- Publish the final Privacy Policy at a stable public HTTPS URL and enter it in App Store Connect. Apple requires a privacy-policy URL and accurate privacy disclosures for the app and third-party partners.
- Make the policy available inside the app; repair the currently missing bundled `Privacy.md` resource. Add Terms access in app if using custom terms / paid flows.
- Generate and review Xcode’s privacy report and inspect all dependencies and embedded SDKs. App Store privacy answers and any privacy manifest must describe actual collection and required-reason API usage; do not invent collection declarations for data the app does not collect.
- Complete App Store Connect privacy nutrition labels based on the release binary and its third-party partners. Revisit them whenever data practices change.
- Before any purchase integration, decide whether “revenue card” means a RevenueCat-powered subscription or another purchase model. Review the chosen SDK’s data practices, manifests, and current Apple payment rules.
- For auto-renewing subscriptions, check current App Review requirements for ongoing value, cross-device availability, clear purchase terms, visible full renewal price, duration, and restore path. Provide accessible Terms and Privacy links in the app and store metadata.
- Re-review this document and both policies after adding sync, analytics, diagnostics, support upload, login, or purchase services.

## Apple sources

- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Manage app privacy in App Store Connect](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy)
- [App privacy details](https://developer.apple.com/app-store/app-privacy-details/)
- [Privacy manifests](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files)
- [Auto-renewable subscriptions](https://developer.apple.com/app-store/subscriptions/)
- [Provide a custom license agreement](https://developer.apple.com/help/app-store-connect/manage-app-information/provide-a-custom-license-agreement)
