{ lib, pkgs, config, ... }:

let
  defaultUser = "inventree";
  defaultGroup = "inventree";
  concatMapAttrsToList = f: attrs:
    lib.concatLists (map (k: f k (attrs.${k})) (lib.attrNames attrs));
in

{
  options.services.inventree = {
    enable = lib.mkEnableOption "Enable InvenTree service";

    instances = lib.mkOption {
      type = lib.types.attrsOf lib.types.attrs;
      default = {};
      description = "Map of independent InvenTree instances";
    };
  };

  config = lib.mkIf config.services.inventree.enable {
    # Create inventree user and group only once
    users.users.${defaultUser} = {
      isSystemUser = true;
      description = "InvenTree daemon user";
      group = defaultGroup;
    };
    users.groups.${defaultGroup} = {};

    # Import overlay for inventree packages
    nixpkgs.overlays = [ (import ./overlay.nix) ];

    environment.systemPackages = 
      concatMapAttrsToList (name: instance:
        if instance.enable then [
          (pkgs.symlinkJoin {
            name = "inventree-invoke-${name}";
            paths = [ pkgs.inventree.invoke ];
            buildInputs = [ pkgs.makeWrapper ];
            postBuild = ''
              wrapProgram $out/bin/inventree-invoke \
                --set INVENTREE_CONFIG_FILE /etc/inventree-${name}-config.yaml
              mv $out/bin/inventree-invoke $out/bin/inventree-invoke-${name}
            '';
          })
        ] else []
      ) config.services.inventree.instances;

    # For each instance, generate tmpfiles rules
    systemd.tmpfiles.rules = concatMapAttrsToList (name: instance:
      if instance.enable then [
        "d ${instance.dataDir}/static 0755 ${defaultUser} ${defaultGroup} -"
        "d ${instance.dataDir}/media 0755 ${defaultUser} ${defaultGroup} -"
        "d ${instance.dataDir}/backup 0755 ${defaultUser} ${defaultGroup} -"
      ] else []
    ) config.services.inventree.instances;

    # Generate environment files for each instance
    environment.etc = lib.foldl' (acc: name:
      let
        instance = config.services.inventree.instances.${name};
      in
      if instance.enable then
        acc // {
          "inventree-${name}-config.yaml" = {
            text = builtins.toJSON instance.config;
          };
          "inventree-${name}-users.json" = {
            text = builtins.toJSON instance.users;
          };
          "secret/inventree-${name}-admin-password" = {
            source = instance.passwordFile;
          };
        }
      else acc
    ) {} (builtins.attrNames config.services.inventree.instances);

    # Generate systemd services for each instance
    systemd.services = lib.concatMapAttrs (name: instance:
      if instance.enable then {
        "inventree-server-${name}" = {
          description = "InvenTree Server instance ${name}";
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" ];
          enable = true;
          serviceConfig = {
            User = defaultUser;
            Group = defaultGroup;
            ExecStart = ''
              ${pkgs.inventree.server}/bin/inventree-server -b ${instance.serverBind}
            '';
            Environment = "INVENTREE_CONFIG_FILE=/etc/inventree-${name}-config.yaml";
            Restart = "on-failure";
          };
        };

        "inventree-cluster-${name}" = {
          description = "InvenTree background worker instance ${name}";
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" ];
          enable = true;
          serviceConfig = {
            User = defaultUser;
            Group = defaultGroup;
            ExecStart = ''
              ${pkgs.inventree.cluster}/bin/inventree-cluster
            '';
            Environment = "INVENTREE_CONFIG_FILE=/etc/inventree-${name}-config.yaml";
            Restart = "on-failure";
          };
        };
      } else {}
    ) config.services.inventree.instances;
  };
}
