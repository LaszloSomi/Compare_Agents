# Microsoft Graph Agent Registry Reference

Source documentation:

- https://learn.microsoft.com/microsoft-agent-365/admin/graph-api
- https://learn.microsoft.com/microsoft-365-copilot/extensibility/api/admin-settings/package/overview
- https://learn.microsoft.com/microsoft-365-copilot/extensibility/api/admin-settings/package/copilotpackages-list
- https://learn.microsoft.com/microsoft-365-copilot/extensibility/api/admin-settings/package/copilotpackagedetail-get

## Requirements

- Microsoft Agent 365 license.
- AI admin or Global admin role.
- Least-privileged delegated permission: `CopilotPackages.Read.All`.
- Work or school account.
- Commercial global service. US Government L4, US Government L5/DoD, and China operated by
  21Vianet are not supported by these APIs as documented.

## Endpoints

List packages:

```http
GET https://graph.microsoft.com/v1.0/copilot/admin/catalog/packages
```

Agent Builder filter:

```text
$filter=platform eq 'Microsoft 365 Copilot Agent Builder'
```

Get package details:

```http
GET https://graph.microsoft.com/v1.0/copilot/admin/catalog/packages/{id}
```

The list API supports filters for `supportedHosts`, `elementTypes`,
`lastModifiedDateTime`, and `platform`. Follow `@odata.nextLink` until it is absent.

Use `v1.0` by default. The `/beta` endpoint is preview and is not supported for production use.

## Relevant detail fields

Package details can include:

- `id`, `displayName`, `type`, `shortDescription`, and `longDescription`
- `isBlocked`, `availableTo`, `deployedTo`, and `allowedUsersAndGroups`
- `supportedHosts`, `categories`, `elementTypes`, and `platform`
- `publisher`, `version`, `manifestVersion`, `manifestId`, `appId`, and `assetId`
- `lastModifiedDateTime`
- `elementDetails`, whose `definition` values can be JSON-encoded strings

The registry metadata might not expose every configured knowledge source or instruction. Report
unknown values and confidence limitations rather than inferring facts that are not returned.

