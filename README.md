# guilddkp
Additions to the old GuildDKP to fit current release of WOW API.

The main focus at this version (1.5.2) is the following functionality:  
  
* /gdhelp                               - for help menu
* /gddkp playername                     - for requesting DKP status of playername
* /gdaddraid int:amount                 - for adding int:amount of DKP to entire raid
* /gdplus playername int:amount         - for adding int:amount to playername
* /gdminus playername int:amount        - for subtracting int:amount from playername

TODO's:
1. Ensure only officers can do DKP control functions
2. Fix GDCLASS
3. Ensure minus cannot go below 0
