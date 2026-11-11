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

    var brand = document.createElement("a");
    var symbol = document.createElement("img");
    var wordmark = document.createElement("span");
    var brandDot = document.createElement("span");

    brand.className = "ptg-brand";
    brand.href = "https://pastthegrid.uk/";
    brand.setAttribute("aria-label", "Past the Grid home");

    symbol.src = identityBase + "identity/symbol-dark.svg";
    symbol.width = 30;
    symbol.height = 30;
    symbol.alt = "";
    symbol.setAttribute("aria-hidden", "true");

    wordmark.appendChild(document.createTextNode("Past the Grid"));
    brandDot.className = "ptg-brand-dot";
    brandDot.textContent = ".";
    wordmark.appendChild(brandDot);
    brand.appendChild(symbol);
    brand.appendChild(wordmark);
    logo.replaceChildren(brand);

    currentApp.innerHTML = [
      '<span class="ptg-brand-separator" aria-hidden="true">/</span>',
      '<span aria-current="page">Cycling Analytics</span>'
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
