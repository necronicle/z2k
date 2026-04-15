-- z2k-fooling-ext.lua
--
-- Extended fooling functions for anti-ТСПУ TTL handling. Plugged into the
-- upstream apply_fooling extension point via `fool=<name>` strategy arg.
--
-- Loaded via --lua-init=@... AFTER zapret-lib.lua (so apply_fooling exists)
-- and BEFORE z2k-autocircular.lua and strategies that reference it. Order is
-- enforced by files/lua cmdline position in lib/install.sh.
--
-- Functions exported to the global namespace (called via `fool=<name>`):
--   z2k_dynamic_ttl — clamp fake packet TTL to real egress TTL minus 1
--
-- Rationale
-- ---------
-- ТСПУ and similar stateful DPI systems detect fake packets by comparing
-- their TTL against the expected client egress TTL (usually 64 on Linux).
-- A hardcoded `ip_ttl=8` fake looks suspicious from 50+ hops away — DPI
-- ignores the fake, keeps inspecting the real flow, and the bypass fails.
--
-- Upstream already ships `ip_autottl=delta:min-max` which does per-
-- connection hop discovery from the first incoming server reply (see
-- zapret-lib.lua:876 ttl_discover). Two weaknesses:
--   1. Needs incoming_ttl cached → doesn't fire on the very first packet
--      of a flow (exactly when DPI is most alert).
--   2. Ties fake TTL to hop count to the server, not to the real egress
--      TTL — works differently at different network positions.
--
-- z2k_dynamic_ttl skips the cache entirely and pegs the fake TTL to
-- `real_dis.ip.ip_ttl - 1` where `real_dis.ip.ip_ttl` is the value
-- visible on the current outgoing packet at the moment the fool hook
-- fires. Because upstream rawsend helpers deepcopy the real dis before
-- handing it to apply_fooling, that value is the original kernel-
-- assigned egress TTL unless the strategy also sets ip_ttl/ip_autottl
-- explicitly (in which case our hook is a no-op — explicit wins).

function z2k_dynamic_ttl(dis, options)
  -- Do not override explicit strategy TTL — if the user set ip_ttl=N or
  -- ip_autottl=delta they meant it, don't fight them. Pure additive mode.
  if dis and dis.ip and dis.ip.ip_ttl and dis.ip.ip_ttl > 1 then
    if not (options and (options.ip_ttl or options.ip_autottl)) then
      local prev = dis.ip.ip_ttl
      dis.ip.ip_ttl = prev - 1
      if type(DLOG) == "function" then
        DLOG("z2k_dynamic_ttl: ipv4 " .. prev .. " -> " .. dis.ip.ip_ttl)
      end
    end
  end
  if dis and dis.ip6 and dis.ip6.ip6_hlim and dis.ip6.ip6_hlim > 1 then
    if not (options and (options.ip6_ttl or options.ip6_autottl)) then
      local prev = dis.ip6.ip6_hlim
      dis.ip6.ip6_hlim = prev - 1
      if type(DLOG) == "function" then
        DLOG("z2k_dynamic_ttl: ipv6 " .. prev .. " -> " .. dis.ip6.ip6_hlim)
      end
    end
  end
end
