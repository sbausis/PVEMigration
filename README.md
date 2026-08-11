# PVEMigration
Tip Powershell Migration Vorbereitung:
- Erkennt ob auf VMware oder Proxmox
  
	Wenn gestartet auf VMware VM:
	- Prüft Windows Version (Treiber-Auswahl)
	- Deinstalliert VMware Tools
	- Speichert die Netzwerkkonfiguration
	- Installiert Qemu Agent
	- Inject VirtIO SCSI Driver (-> direkt booten auf Proxmox ohne SCSI Driver Probleme, Storage Kontroller von Anfang an SCSI)
	- Installiert VirtIO Driver Package
	- Erstellt einen Scheduled Task welcher automatisch nach Neustart auf Proxmox startet
 
   Wenn gestartet auf Proxmox VM:
	- Bereinigt VMware Hardware in Geräte-Manager
	- Setzt die Netzwerkkonfiguration (VirtIO Net und gleiche MAC ist ein Muss)
	- Entfernt Scheduled Task

Vorgehen:

- VirtIO ISO Links auf selbstgewählte Source setzen (Suche nach https://xxxx.xxx/pve/)
- devcon.exe und devcon32.exe zur PS1 Datei legen (https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/devcon)
- Script mit PVEMigration.ps1 -MakeEXE zu PVEMigration.exe machen
- EXE auf VM in c:\TEMP ablegen und ausführen (beinhaltet devcon)
- VMware Maschine herunterfahren
- Proxmox Maschine hochfahren
- Fertig
