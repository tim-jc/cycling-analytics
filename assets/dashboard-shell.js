(function () {
  var identityScript = document.currentScript;
  var identityBase = identityScript && identityScript.src
    ? identityScript.src.replace(/dashboard-shell\.js(?:\?.*)?$/, "")
    : "";

  function installCyclingAnalyticsBrand() {
    var navbar = document.querySelector(".navbar");
    var logo = document.querySelector(".navbar-logo");
    var currentApp = document.querySelector(".navbar-brand");
    var toggle = document.getElementById("navbar-button");

    if (!navbar || !logo || !currentApp || navbar.dataset.ptgBrandInstalled) {
      return;
    }

    navbar.dataset.ptgBrandInstalled = "true";
    navbar.setAttribute("aria-label", "Cycling Analytics navigation");

    document.querySelectorAll('link[rel~="icon"][href="data:image/x-icon;"]')
      .forEach(function (link) { link.remove(); });

    logo.innerHTML = [
      '<a class="ptg-brand" href="https://pastthegrid.uk/"',
      ' aria-label="Past the Grid home">',
      '<img src="' + identityBase + 'identity/symbol-dark.svg"',
      ' width="28" height="28" alt="" aria-hidden="true">',
      '<span>Past the Grid<span class="ptg-brand-dot">.</span></span>',
      '</a>'
    ].join("");

    currentApp.innerHTML = [
      '<span class="ptg-brand-separator" aria-hidden="true">/</span>',
      '<span>Cycling Analytics</span>'
    ].join("");

    if (toggle) {
      toggle.setAttribute("aria-label", "Toggle dashboard navigation");
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", installCyclingAnalyticsBrand);
  } else {
    installCyclingAnalyticsBrand();
  }
}());
