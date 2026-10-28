# Copyright 2026 Reilley64
# Distributed under the terms of the GNU General Public License v2

EAPI=8

DESCRIPTION="Workload orchestrator, official HashiCorp release binary"
HOMEPAGE="https://www.nomadproject.io"
SRC_URI="https://releases.hashicorp.com/nomad/${PV}/nomad_${PV}_linux_amd64.zip"
S="${WORKDIR}"

LICENSE="BUSL-1.1"
SLOT="0"
KEYWORDS="-* amd64"
RESTRICT="mirror strip bindist"

BDEPEND="app-arch/unzip"
RDEPEND="
	!sys-cluster/nomad
	app-containers/cni-plugins
"

QA_PREBUILT="usr/bin/nomad"

src_install() {
	dobin nomad
}
