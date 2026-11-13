# Code organization

The macOS package is organized by feature. Start at the user-facing feature,
then follow its UI workflow into its model, policy or repository. The Xcode
application keeps its existing identity and imports the `RemarcFeature` product.

```text
app/Remarc/RemarcApp.swift              Application bootstrap
app/RemarcPackage/
  Package.swift                       Compilation boundaries and dependencies
  Sources/
    App/                              Lifecycle, routing, menu bar, dependency wiring
    Features/
      Comments/                       Comment document, sessions, history and export
      Capture/                        Text selection, screenshots, annotation and storage
      Integrations/                   Agent clients, browser bridge, webhooks and PopClip
      Settings/                       Preferences and settings panes
      SnapshotSync/                   iCloud snapshots, comparison, publication and recovery
      Updates/                        GitHub release discovery, Sparkle installation and recovery backups
      Onboarding/                     First-run permission guidance
    Core/
      Platform/                       Identity, app paths, logging, process execution and locks
      Localization/                   Localization lookup, language state and resources
      Theme/                          Semantic colors, gradients and shared metrics
      UI/                             Reusable views and native window mechanisms
  Tests/RemarcFeatureTests/
    App/
    Core/
    Features/
    Architecture/
    Support/
    Fixtures/
tests/architecture/                   Swift dependency and source-ownership checks
```

## Compilation ownership

One package contains four `Core*` targets, seven `Feature*` targets, and the
`RemarcFeature` application-composition target. A folder does not itself create a
Swift module; `Package.swift` declares the actual boundaries.

Each feature target owns the models, policies and independent capabilities in
its feature folder. The `UI/` subfolder contains application workflows that
coordinate multiple features and is compiled by `RemarcFeature`. This keeps all
code for a user-visible feature together without making lower targets depend on
the application. Standalone annotation UI and onboarding can live directly in
their feature targets because they have no application dependencies.

`RemarcFeature` compiles `App/` and the six feature `UI/` subfolders. Its manifest
excludes every lower target's sources. Architecture checks verify that every
Swift file has exactly one compilation owner in both standard and Ventura
profiles. When adding a lower-target source directory, update that exclusion
list with its feature's target declaration.

Dependencies flow from application composition to features to core. Feature
dependencies are explicit: snapshots use comment and capture contracts;
settings use the features whose preferences they edit; onboarding uses capture
permissions and agent installation status. Core never imports a feature.

Use explicit imports and narrowly scoped `public` or `package` declarations.
Keep implementation details `private` or module-internal. Do not introduce
re-export barrels, duplicate contract types or per-method forwarding wrappers.

## Workflow boundaries

- `App/AppServices.swift` creates the application-lifetime comment store and
  lazily assembles capture and snapshot workflows. It maps comment changes to
  webhook delivery; comment mutation code does not call the webhook service.
- `Comments/Model` owns the stored document contract, including captured web
  context. The browser supplies explicit privacy choices; document models do
  not fetch settings from the application.
- `Comments/Repository` owns document reads, three-way merge, serialized writes
  and fresh-read transactions. `Comments/UI/Service/CommentStore*` coordinates
  observable state, retention, snapshots and capture commits. Its extensions
  share the same state and transaction gates; they do not create independent
  writers.
- `Capture/UI/Screenshot/ScreenshotComposer.swift` describes the editor support
  required by `ScreenCaptureCoordinator`. The application supplies the concrete
  comment editor. `RegionSelectionView` and annotation components remain capture
  implementation details.
- `SnapshotSync/SnapshotDocumentStore.swift` is a consumer-owned transaction
  port. The snapshot manager receives it through its initializer; the
  application makes `CommentStore` conform to it.
- Settings preference contracts live with their owning features. Settings panes
  are separated by capability. `AgentIntegrationSettingsViewModel` owns install
  progress and CLI actions; views bind to its state.
- Dock-policy mechanics live in `Core/UI`. The application supplies the user's
  preference; the mechanism does not import settings.

The application workflows retain their existing shared UI controllers where a
single native window is part of their lifecycle. Feature targets do not reach
back into those controllers or the `AppServices` container.

## Data and delivery invariants

Directory changes must not change `comments.json`, defaults keys, image paths,
MCP contracts, lock ownership, unknown-field preservation or transaction order.
The app, MCP server and hooks still coordinate on one document and its existing
cross-process lock. Session and comment repositories do not own separate files.

Production and development continue to use `AppIdentity.current` for isolated
storage, snapshots, notifications and integrations. Standard and Ventura share
the same pinned dependencies and keep their availability guards. Resource bundles belong to
their compiling target: localization resources belong to `CoreLocalization`;
application resources remain under `App/Resources`.

Production builds and signing remain GitHub-only. A local native build produces
and relaunches `Remarc Dev` through the existing development scripts.

## Verification

From the repository root:

```sh
python3 -m unittest discover -s tests/architecture -v
bash scripts/resolve-packages.sh "$(pwd)/app/RemarcPackage"
swift test --package-path "$(pwd)/app/RemarcPackage"
REMARC_VENTURA=1 swift test --package-path "$(pwd)/app/RemarcPackage"
```

The Ventura suite checks the compatibility configuration on the current host.
It does not establish Intel or Ventura runtime compatibility; that requires the
explicit native-host verification described in `AGENTS.md` and `RELEASING.md`.
