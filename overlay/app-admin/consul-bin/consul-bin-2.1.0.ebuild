# Copyright 2026 Reilley64
# Distributed under the terms of the GNU General Public License v2

EAPI=8

DESCRIPTION="Service networking platform, official HashiCorp release binary"
HOMEPAGE="https://www.consul.io"
SRC_URI="https://releases.hashicorp.com/consul/${PV}/consul_${PV}_linux_amd64.zip"
S="${WORKDIR}"

LICENSE="BUSL-1.1"
SLOT="0"
KEYWORDS="-* amd64"
RESTRICT="mirror strip bindist"

BDEPEND="app-arch/unzip"
RDEPEND="
	!app-admin/consul
	acct-group/consul
	acct-user/consul
"

QA_PREBUILT="usr/bin/consul"

src_install() {
	dobin consul
}
