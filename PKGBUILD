# Maintainer: Ron <thefangeddeity>
pkgname=arch-sdcard-updater
pkgver=1.1.0
pkgrel=1
pkgdesc="Space-aware incremental package updater for Arch Linux on SD cards"
arch=('any')
url="https://github.com/thefangeddeity/arch-sdcard-updater"
license=('GPL3')
depends=('bash' 'yay' 'expac' 'tmux')
source=("$pkgname-$pkgver.tar.gz::https://github.com/thefangeddeity/$pkgname/archive/refs/tags/v$pkgver.tar.gz")
sha256sums=('7946dcb0686b7703e5f704c7ada4f0cdd93e45f0d8daf99ff5b562de7313a867')

package() {
    cd "$pkgname-$pkgver"
    install -Dm755 arch-sdcard-updater.sh "$pkgdir/usr/bin/arch-sdcard-updater"
    ln -s /usr/bin/arch-sdcard-updater "$pkgdir/usr/bin/sdupdate"
    install -Dm644 README.md "$pkgdir/usr/share/doc/$pkgname/README.md"
}
