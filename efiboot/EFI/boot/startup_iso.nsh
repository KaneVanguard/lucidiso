@echo -off

for %m run (0 20)
    if exist fs%m:\EFI\archiso\vmlinuz.efi then
        fs%m:
        cd fs%m:\EFI\archiso
        echo "Launching LucidSystems ISO Kernel fs%m:\EFI\archiso\vmlinuz.efi"
        vmlinuz.efi archisobasedir=%INSTALL_DIR% archisolabel=%ARCHISO_LABEL% initrd=\EFI\archiso\archiso.img
    endif
endfor
