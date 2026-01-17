(() => {
  const DEFAULT_CFG = {
    weapons: {
      useLocal: true,
      useRemote: true,
      remoteBase: "https://docs.fivem.net/weapons/",
      localBase: "images/weapons/",
      placeholder: "images/weapons/_default.png",
      aliases: {}
    },
    attachments: {
      placeholder: "images/attachments/_default.png"
    }
  };

  let CFG = JSON.parse(JSON.stringify(DEFAULT_CFG));

  function merge(dst, src) {
    if (!src || typeof src !== "object") return dst;
    for (const k of Object.keys(src)) {
      if (src[k] && typeof src[k] === "object" && !Array.isArray(src[k])) {
        dst[k] = merge(dst[k] || {}, src[k]);
      } else {
        dst[k] = src[k];
      }
    }
    return dst;
  }

  function normalizeWeaponHash(input) {
    if (!input) return null;

    let s = String(input).trim();
    if (!s) return null;

    const lower = s.toLowerCase().replace(/\s+/g, "_").replace(/-+/g, "_");
    const aliases = (CFG.weapons && CFG.weapons.aliases) || {};
    if (aliases[lower]) return String(aliases[lower]).toUpperCase();

    if (lower.startsWith("weapon_")) return ("WEAPON_" + lower.slice(7)).toUpperCase();
    if (lower.startsWith("weapon") && !lower.startsWith("weapon_")) return ("WEAPON_" + lower.slice(6)).toUpperCase();

    const up = s.toUpperCase();
    if (up.startsWith("WEAPON_")) return up;

    return ("WEAPON_" + lower).toUpperCase();
  }

  function isWeaponLike(item) {
    const candidates = [
      item?.weaponHash, item?.hash, item?.weapon,
      item?.name, item?.item, item?.key, item?.id
    ].filter(Boolean);

    for (const v of candidates) {
      const t = String(v).toLowerCase();
      if (t.startsWith("weapon_") || t.startsWith("weapon") || t.startsWith("WEAPON_".toLowerCase())) return true;
    }
    return false;
  }

  function weaponSrcList(hash) {
    const w = CFG.weapons || DEFAULT_CFG.weapons;
    const out = [];
    if (w.useLocal && w.localBase) out.push(`${w.localBase}${hash}.png`);
    if (w.useRemote && w.remoteBase) out.push(`${w.remoteBase}${hash}.png`);
    out.push(w.placeholder || DEFAULT_CFG.weapons.placeholder);
    return out.filter(Boolean);
  }

  function setImgFallback(img, srcs) {
    if (!img || !srcs?.length) return;

    let i = 0;
    img.loading = "lazy";
    img.decoding = "async";
    img.referrerPolicy = "no-referrer";

    const next = () => {
      if (i >= srcs.length) return;
      img.src = srcs[i++];
    };

    img.onerror = () => next();
    img.onload = () => img.classList.add("loaded");
    next();
  }

  function applyItemImage(imgEl, item) {
    if (!imgEl) return;

    // If item already has an explicit image, still allow fallback if it fails.
    const explicit = item?.image || item?.img || item?.icon;
    if (explicit) {
      setImgFallback(imgEl, [explicit, CFG.weapons?.placeholder || DEFAULT_CFG.weapons.placeholder]);
      return;
    }

    if (!isWeaponLike(item)) {
      // Non-weapon: leave as-is or use your own item placeholder
      return;
    }

    const hash = normalizeWeaponHash(item?.weaponHash || item?.hash || item?.weapon || item?.name || item?.key || item?.id);
    if (!hash) return;

    setImgFallback(imgEl, weaponSrcList(hash));
  }

  function renderAttachments(container, components) {
    if (!container) return;
    container.innerHTML = "";

    if (!Array.isArray(components) || components.length === 0) {
      container.style.display = "none";
      return;
    }
    container.style.display = "";

    for (const c of components) {
      const row = document.createElement("div");
      row.className = "attRow";

      const label = document.createElement("div");
      label.className = "attLabel";
      label.textContent = c.label || c.id || "Attachment";

      const chip = document.createElement("div");
      chip.className = "attChip";
      chip.textContent = String(c.slot || "slot").toUpperCase();

      row.appendChild(label);
      row.appendChild(chip);
      container.appendChild(row);
    }
  }

  function renderAttachmentPicker(container, components, selectedSet) {
    if (!container) return;
    container.innerHTML = "";
    selectedSet = selectedSet || new Set();

    if (!Array.isArray(components) || components.length === 0) {
      container.style.display = "none";
      return;
    }
    container.style.display = "";

    for (const c of components) {
      const id = c.id || c;
      if (!id) continue;

      const pill = document.createElement("div");
      pill.className = "pick";
      pill.textContent = c.label || id;

      const on = selectedSet.has(id);
      if (on) pill.classList.add("on");

      pill.onclick = () => {
        if (selectedSet.has(id)) {
          selectedSet.delete(id);
          pill.classList.remove("on");
        } else {
          selectedSet.add(id);
          pill.classList.add("on");
        }
      };

      container.appendChild(pill);
    }

    return selectedSet;
  }

  window.AzInvMedia = {
    setConfig(cfg) { CFG = merge(CFG, cfg || {}); },
    getConfig() { return CFG; },
    normalizeWeaponHash,
    applyItemImage,
    renderAttachments,
    renderAttachmentPicker
  };

  window.addEventListener("message", (e) => {
    const d = e.data;
    if (d?.action === "setConfig" && d.cfg) window.AzInvMedia.setConfig(d.cfg);
  });
})();
