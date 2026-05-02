# Maintainer: Ron <thefangeddeity>
pkgname=arch-sdcard-updater
pkgver=0.2.0
pkgrel=1
pkgdesc="Space-aware incremental package updater for Arch Linux on SD cards"
arch=('any')
url="https://github.com/thefangeddeity/arch-sdcard-updater"
license=('GPL3')
depends=('bash' 'yay' 'expac')
source=("$pkgname-$pkgver.tar.gz::https://github.com/thefangeddeity/$pkgname/archive/refs/tags/v$pkgver.tar.gz")
sha256sums=('d59d471634abb65620cdc47f8411260c20db9103de7665793b062602a357e931')

package() {
    cd "$pkgname-$pkgver"
    install -Dm755 arch-sdcard-updater.sh "$pkgdir/usr/bin/arch-sdcard-updater"
    ln -s /usr/bin/arch-sdcard-updater "$pkgdir/usr/bin/sdupdate"
    install -Dm644 README.md "$pkgdir/usr/share/doc/$pkgname/README.md"
}
