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

    installMobileNavigationClose(navbar, toggle);
  }

  function installMobileNavigationClose(navbar, toggle) {
    var collapse = navbar.querySelector(".navbar-collapse");

    if (!collapse || !toggle || collapse.dataset.pageCloseInstalled) {
      return;
    }

    collapse.dataset.pageCloseInstalled = "true";

    collapse.addEventListener("click", function (event) {
      var link = event.target.closest('.navbar-nav a[href^="#"]');
      var isCompactNavigation = window.matchMedia("(max-width: 767px)").matches;
      var isExpanded = collapse.classList.contains("in") ||
        collapse.classList.contains("show");

      if (!link || !collapse.contains(link) || !isCompactNavigation || !isExpanded) {
        return;
      }

      if (window.jQuery && typeof window.jQuery.fn.collapse === "function") {
        window.jQuery(collapse).one("hidden.bs.collapse", function () {
          window.setTimeout(function () {
            toggle.focus();
          }, 0);
        });
        window.jQuery(collapse).collapse("hide");
      } else {
        collapse.classList.remove("in", "show");
        collapse.setAttribute("aria-expanded", "false");
        toggle.classList.add("collapsed");
        toggle.setAttribute("aria-expanded", "false");
        toggle.focus();
      }
    });
  }

  function annotateLinkedValueBoxes() {
    document.querySelectorAll('.value-output[data-href]').forEach(function (output) {
      var container = output.closest('.section.level3');
      var href = output.getAttribute('data-href');

      if (container && href) {
        container.setAttribute('data-ptg-value-box-href', href);
      }
    });
  }

  function promoteLinkedValueBoxes() {
    document.querySelectorAll('.value-box[data-ptg-value-box-href]').forEach(function (box) {
      var href = box.getAttribute('data-ptg-value-box-href');
      var link = document.createElement('a');

      Array.from(box.attributes).forEach(function (attribute) {
        if (attribute.name !== 'data-ptg-value-box-href') {
          link.setAttribute(attribute.name, attribute.value);
        }
      });

      link.classList.add('value-box-link');
      link.href = href;
      if (/^https?:\/\//i.test(href)) {
        link.target = '_blank';
        link.rel = 'noopener noreferrer';
      }

      while (box.firstChild) {
        link.appendChild(box.firstChild);
      }
      box.replaceWith(link);
    });
  }

  function installAccessibleValueBoxLinks() {
    var dashboard = document.getElementById('dashboard-container');

    annotateLinkedValueBoxes();
    if (window.jQuery && dashboard) {
      window.jQuery(dashboard).one(
        'flexdashboard:layoutcomplete',
        promoteLinkedValueBoxes
      );
    }
    window.setTimeout(promoteLinkedValueBoxes, 0);
  }

  function installCyclingAnalyticsShell() {
    installCyclingAnalyticsBrand();
    installAccessibleValueBoxLinks();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", installCyclingAnalyticsShell);
  } else {
    installCyclingAnalyticsShell();
  }
}());
