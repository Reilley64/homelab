# Copyright 2026 Reilley64
# Distributed under the terms of the GNU General Public License v2

EAPI=8

DESCRIPTION="Secrets management tool, official HashiCorp release binary"
HOMEPAGE="https://www.vaultproject.io"
SRC_URI="https://releases.hashicorp.com/vault/${PV}/vault_${PV}_linux_amd64.zip"
S="${WORKDIR}"

LICENSE="BUSL-1.1"
SLOT="0"
KEYWORDS="-* amd64"
RESTRICT="mirror strip bindist"

BDEPEND="app-arch/unzip"
RDEPEND="
	!app-admin/vault
	acct-group/vault
	acct-user/vault
"

QA_PREBUILT="usr/bin/vault"

src_install() {
	dobin vault
}
