TopTalentCheck - instalacion
============================

1) Copia la carpeta TopTalentCheck a:
   <WoW>\_retail_\Interface\AddOns\

2) Ajusta la version en TopTalentCheck.toc ("## Interface:"). En el juego:
   /dump (select(4, GetBuildInfo()))

3) Busca en la carpeta de Raider.IO el archivo con los builds:
   <WoW>\_retail_\Interface\AddOns\RaiderIO\

   PowerShell (ignora core.lua, que tambien lo menciona; te interesa el OTRO archivo):
   Get-ChildItem "C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns\RaiderIO" -Recurse -Filter *.lua | Select-String -Pattern "TALENT_BUILDS" -List | Select-Object Path

4) Copia ese archivo a TopTalentCheck\Data\TalentBuilds.lua (sobrescribe el placeholder).
   Repite este paso cada vez que Raider.IO actualice sus datos: el addon avisa al
   iniciar si los datos tienen mas de 10 dias.

5) /reload y proba con:  /ttc     (comprueba ahora, sin esperar un ready check)
                         /ttc copy (ventana para copiar el string del build top)

Datos de Raider.IO: uso personal. Si lo publicas, pedi permiso a Raider.IO.
