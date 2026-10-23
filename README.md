# theplatform

Terraform + Azure + GitHub Actions platform hosting Lambari.

## Bootstrap (one-time, local)

Creates per-env OIDC identities, resource groups, HCP Terraform workspaces, GitHub environments, and a $1 budget alert.

```sh
az login
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
export GITHUB_TOKEN=$(gh auth token)
terraform login            # HCP Terraform token for the tfe provider

cd infra/bootstrap
cat > terraform.tfvars <<EOF
hcp_org     = "<your HCP org>"
alert_email = "<you@example.com>"
EOF
terraform init && terraform apply

# CI identities are RG-scoped and can't register resource providers themselves.
az provider register --namespace Microsoft.App --wait
```

Then give CI access to state (team token from HCP → Settings → Teams → owners):

```sh
gh secret set TF_API_TOKEN
```

Verify OIDC trust (subject must be `repo:Inn-Keeper/theplatform:environment:<env>`):

```sh
az ad app federated-credential list --id <client_id> --query "[].subject"
```
