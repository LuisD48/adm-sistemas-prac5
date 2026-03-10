# Practica 5 - Servidor FTP
**Alumno:** Laurean Acosta Luis Donaldo  
**Materia:** Administracion de Sistemas  

---

## Estructura del Repositorio

```
adm-sistemas-prac5/
├── linux/
│   ├── main.sh                  <- Punto de entrada (sudo bash main.sh)
│   └── lib/
│       ├── funciones_comunes.sh <- Utilidades compartidas
│       └── funciones_ftp.sh     <- Modulo FTP (vsftpd)
│
├── windows/
│   ├── Main.ps1                 <- Punto de entrada (.\Main.ps1)
│   └── lib/
│       ├── FuncionesComunes.ps1 <- Utilidades compartidas
│       └── FuncionesFTP.ps1     <- Modulo FTP (IIS)
│
└── README.md
```

---

## Estructura de Directorios FTP

```
Linux:   /srv/ftp/
Windows: C:\inetpub\ftproot\
         |
         |-- general/        <- Anonimo: lectura | Autenticado: escritura
         |-- reprobados/     <- Solo miembros del grupo reprobados
         |-- recursadores/   <- Solo miembros del grupo recursadores
         |-- [usuario]/      <- Carpeta personal de cada usuario
```

---

## Uso

### Linux (OpenSUSE)
```bash
wget https://raw.githubusercontent.com/LuisD48/adm-sistemas-prac5/main/linux/main.sh
wget https://raw.githubusercontent.com/LuisD48/adm-sistemas-prac5/main/linux/lib/funciones_comunes.sh -P lib/
wget https://raw.githubusercontent.com/LuisD48/adm-sistemas-prac5/main/linux/lib/funciones_ftp.sh -P lib/
sudo bash main.sh
```

### Windows Server
```powershell
git clone https://github.com/LuisD48/adm-sistemas-prac5.git
cd adm-sistemas-prac5\windows
.\Main.ps1
```

---

## Modos de Acceso FTP

| Usuario     | /general       | /reprobados | /recursadores | /personal |
|-------------|----------------|-------------|---------------|-----------|
| Anonimo     | Solo lectura   | Sin acceso  | Sin acceso    | Sin acceso|
| reprobados  | Leer + Escribir| Leer + Escribir | Sin acceso | Solo suyo |
| recursadores| Leer + Escribir| Sin acceso  | Leer + Escribir| Solo suyo|
