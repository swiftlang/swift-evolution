// ===--- index.js - Swift Evolution --------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2018 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
// ===---------------------------------------------------------------------===//

'use strict'


/** Holds the primary data used on this page: metadata about Swift Evolution proposals. */
let proposals;

/**
 * To be updated when proposals are confirmed to have been implemented
 * in a new language version.
 */
const languageVersions = ['2.2', '3', '3.0.1', '3.1', '4', '4.1', '4.2', '5'];

/** Storage for the user's current selection of filters when filtering is toggled off. */
let filterSelection = [];

const GITHUB_BASE_URL = 'https://github.com/';
const REPO_PROPOSALS_BASE_URL = `${GITHUB_BASE_URL}apple/swift-evolution/blob/master/proposals`;

/**
 * `name`: Mapping of the states in the proposals JSON to human-readable names.
 *
 * `shortName`:  Mapping of the states in the proposals JSON to short human-readable names.
 *  Used for the left-hand column of proposal statuses.
 *
 * `className`: Mapping of states in the proposals JSON to the CSS class names used
 * to manipulate and display proposals based on their status.
 */
const states = {
  '.awaitingReview': {
    name: 'Awaiting Review',
    shortName: 'Awaiting Review',
    className: 'awaiting-review'
  },
  '.scheduledForReview': {
    name: 'Scheduled for Review',
    shortName: 'Scheduled',
    className: 'scheduled-for-review'
  },
  '.activeReview': {
    name: 'Active Review',
    shortName: 'Active Review',
    className: 'active-review'
  },
  '.returnedForRevision': {
    name: 'Returned for Revision',
    shortName: 'Returned',
    className: 'returned-for-revision'
  },
  '.withdrawn': {
    name: 'Withdrawn',
    shortName: 'Withdrawn',
    className: 'withdrawn'
  },
  '.deferred': {
    name: 'Deferred',
    shortName: 'Deferred',
    className: 'deferred'
  },
  '.accepted': {
    name: 'Accepted',
    shortName: 'Accepted',
    className: 'accepted'
  },
  '.acceptedWithRevisions': {
    name: 'Accepted with revisions',
    shortName: 'Accepted',
    className: 'accepted-with-revisions'
  },
  '.rejected': {
    name: 'Rejected',
    shortName: 'Rejected',
    className: 'rejected'
  },
  '.implemented': {
    name: 'Implemented',
    shortName: 'Implemented',
    className: 'implemented'
  },
  '.error': {
    name: 'Error',
    shortName: 'Error',
    className: 'error'
  }
};

init()

/** Primary entry point. */
function init () {
  const req = new window.XMLHttpRequest();

  req.addEventListener('load', e => {
    proposals = JSON.parse(req.responseText)

    // don't display malformed proposals
    proposals = proposals.filter(proposal => !proposal.errors)

    // descending numeric sort based the numeric nnnn in a proposal ID's SE-nnnn
    proposals.sort(function compareProposalIDs (p1, p2) {
      return parseInt(p1.id.match(/\d\d\d\d/)[0]) - parseInt(p2.id.match(/\d\d\d\d/)[0])
    })
    proposals = proposals.reverse()

    render()
    addEventListeners()

    // apply filters when the page loads with a search already filled out.
    // typically this happens after navigating backwards in a tab's history.
    if (document.querySelector('#search-filter').value.trim()) {
      filterProposals()
    }

    // apply selections from the current page's URI fragment
    _applyFragment(document.location.hash)
  })

  req.addEventListener('error', e => {
    document.querySelector('#proposals-count').innerText = 'Proposal data failed to load.'
  })

  req.open('get', 'https://data.swift.org/swift-evolution/proposals')
  req.send()
}

/**
 * Creates an Element. Convenience wrapper for `document.createElement`.
 *
 * @param {string} elementType - The tag name. 'div', 'span', etc.
 * @param {string[]} attributes - A list of attributes. Use `className` for `class`.
 * @param {(string | Element)[]} children - A list of either text or other Elements to be nested under this Element.
 * @returns {Element} The new node.
 */
function html (elementType, attributes, children) {
  const element = document.createElement(elementType);

  if (attributes) {
    Object.keys(attributes).forEach(attributeName => {
      const value = attributes[attributeName];
      if (attributeName === 'className') attributeName = 'class'
      element.setAttribute(attributeName, value)
    })
  }

  if (!children) return element
  if (!Array.isArray(children)) children = [children]

  children.forEach(child => {
    if (!child) {
      console.warn(`Null child ignored during creation of ${elementType}`)
      return
    }
    if (Object.getPrototypeOf(child) === String.prototype) {
      child = document.createTextNode(child)
    }

    element.appendChild(child)
  })

  return element
}

/**
 * Adds the dynamic portions of the page to the DOM, primarily the list
 * of proposals and list of statuses used for filtering.
 *
 * These `render` functions are only called once when the page loads,
 * the rest of the interactivity is based on toggling `display: none`.
 */
function render () {
  renderNav()
  renderBody()
}

/** Renders the top navigation bar. */
function renderNav () {
  const nav = document.querySelector('nav');

  // This list intentionally omits .acceptedWithRevisions and .error;
  // .acceptedWithRevisions proposals are combined in the filtering UI
  // with .accepted proposals.
  const checkboxes = [
    '.awaitingReview', '.scheduledForReview', '.activeReview', '.accepted',
    '.implemented', '.returnedForRevision', '.deferred', '.rejected', '.withdrawn'
  ].map(state => {
    const className = states[state].className;

    return html('li', null, [
      html('input', { type: 'checkbox', className: 'filtered-by-status', id: `filter-by-${className}`, value: className }),
      html('label', { className, tabindex: '0', role: 'button', 'for': `filter-by-${className}` }, [
        states[state].name
      ])
    ])
  });

  const expandableArea = html('div', { className: 'filter-options expandable' }, [
    html('h5', { id: 'filter-options-label' }, 'Status'),
    html('ul', { className: 'filter-by-status' })
  ]);

  nav.querySelector('.nav-contents').appendChild(expandableArea)

  checkboxes.forEach(box => {
    nav.querySelector('.filter-by-status').appendChild(box)
  })

  // The 'Implemented' filter selection gets an extra row of options if selected.
  const implementedCheckboxIfPresent = checkboxes.filter(cb => cb.querySelector(`#filter-by-${states['.implemented'].className}`))[0];

  if (implementedCheckboxIfPresent) {
    // add an extra row of options to filter by language version
    const versionRowHeader = html('h5', { id: 'version-options-label', className: 'hidden' }, 'Language Version');
    const versionRow = html('ul', { id: 'version-options', className: 'filter-by-status hidden' });

    const versionOptions = languageVersions.map(version => html('li', null, [
      html('input', {
        type: 'checkbox',
        id: `filter-by-swift-${_idSafeName(version)}`,
        className: 'filter-by-swift-version',
        value: `swift-${_idSafeName(version)}`
      }),
      html('label', {
        tabindex: '0',
        role: 'button',
        'for': `filter-by-swift-${_idSafeName(version)}`
      }, `Swift ${version}`)
    ]));

    versionOptions.forEach(version => {
      versionRow.appendChild(version)
    })

    expandableArea.appendChild(versionRowHeader)
    expandableArea.appendChild(versionRow)
  }

  return nav
}

/** Displays the main list of proposals that takes up the majority of the page. */
function renderBody () {
  const article = document.querySelector('article');

  const proposalAttachPoint = article.querySelector('.proposals-list');

  const proposalPresentationOrder = [
    '.awaitingReview', '.scheduledForReview', '.activeReview', '.accepted',
    '.acceptedWithRevisions', '.implemented', '.returnedForRevision', '.deferred', '.rejected', '.withdrawn'
  ];

  proposalPresentationOrder.map(state => {
    const matchingProposals = proposals.filter(p => p.status && p.status.state === state);
    matchingProposals.map(proposal => {
      const proposalBody = html('section', { id: proposal.id, className: `proposal ${proposal.id}` }, [
        html('div', { className: 'status-pill-container' }, [
          html('span', { className: `status-pill color-${states[state].className}` }, [
            states[proposal.status.state].shortName
          ])
        ]),
        html('div', { className: 'proposal-content' }, [
          html('div', { className: 'proposal-header' }, [
            html('span', { className: 'proposal-id' }, [
              proposal.id
            ]),
            html('h4', { className: 'proposal-title' }, [
              html('a', {
                href: `${REPO_PROPOSALS_BASE_URL}/${proposal.link}`,
                target: '_blank'
              }, [
                proposal.title
              ])
            ])
          ])
        ])
      ]);

      const detailNodes = [];
      detailNodes.push(renderAuthors(proposal.authors))

      if (proposal.reviewManager.name) detailNodes.push(renderReviewManager(proposal.reviewManager))
      if (proposal.trackingBugs) detailNodes.push(renderTrackingBugs(proposal.trackingBugs))
      if (state === '.implemented') detailNodes.push(renderVersion(proposal.status.version))
      if (proposal.implementation) detailNodes.push(renderImplementation(proposal.implementation))
      if (state === '.acceptedWithRevisions') detailNodes.push(renderStatus(proposal.status))

      if (state === '.activeReview' || state === '.scheduledForReview') {
        detailNodes.push(renderStatus(proposal.status))
        detailNodes.push(renderReviewPeriod(proposal.status))
      }

      if (state === '.returnedForRevision') {
        detailNodes.push(renderStatus(proposal.status))
      }

      const details = html('div', { className: 'proposal-details' }, detailNodes);

      proposalBody.querySelector('.proposal-content').appendChild(details)
      proposalAttachPoint.appendChild(proposalBody)
    })
  })

  // Update the "(n) proposals" text
  updateProposalsCount(article.querySelectorAll('.proposal').length)

  return article
}

/** Authors have a `name` and optional `link`. */
function renderAuthors (authors) {
  let authorNodes = authors.map(author => {
    if (author.link.length > 0) {
      return html('a', { href: author.link, target: '_blank' }, author.name)
    } else {
      return document.createTextNode(author.name)
    }
  });

  authorNodes = _joinNodes(authorNodes, ', ')

  return html('div', { className: 'authors proposal-detail' }, [
    html('div', { className: 'proposal-detail-label' },
      authors.length > 1 ? 'Authors: ' : 'Author: '
    ),
    html('div', { className: 'proposal-detail-value' }, authorNodes)
  ])
}

/** Review managers have a `name` and optional `link`. */
function renderReviewManager (reviewManager) {
  return html('div', { className: 'review-manager proposal-detail' }, [
    html('div', { className: 'proposal-detail-label' }, 'Review Manager: '),
    html('div', { className: 'proposal-detail-value' }, [
      reviewManager.link
        ? html('a', { href: reviewManager.link, target: '_blank' }, reviewManager.name)
        : reviewManager.name
    ])
  ])
}

/** Tracking bugs linked in a proposal are updated via bugs.swift.org. */
function renderTrackingBugs (bugs) {
  let bugNodes = bugs.map(bug => html('a', { href: bug.link, target: '_blank' }, [
    bug.id,
    ' (',
    bug.assignee || 'Unassigned',
    ', ',
    bug.status,
    ')'
  ]));

  bugNodes = _joinNodes(bugNodes, ', ')

  return html('div', { className: 'proposal-detail' }, [
    html('div', { className: 'proposal-detail-label' }, [
      bugs.length > 1 ? 'Bugs: ' : 'Bug: '
    ]),
    html('div', { className: 'bug-list proposal-detail-value' },
      bugNodes
    )
  ])
}

/** Implementations are required alongside proposals (after Swift 4.0). */
function renderImplementation (implementations) {
  let implNodes = implementations.map(impl => html('a', {
    href: `${GITHUB_BASE_URL + impl.account}/${impl.repository}/${impl.type}/${impl.id}`
  }, [
    impl.repository,
    impl.type === 'pull' ? '#' : '@',
    impl.id.substr(0, 7)
  ]));

  implNodes = _joinNodes(implNodes, ', ')

  const label = 'Implementation: ';

  return html('div', { className: 'proposal-detail' }, [
    html('div', { className: 'proposal-detail-label' }, [label]),
    html('div', { className: 'implementation-list proposal-detail-value' },
      implNodes
    )
  ])
}

/** For `.implemented` proposals, display the version of Swift in which they first appeared. */
function renderVersion (version) {
  return html('div', { className: 'proposal-detail' }, [
    html('div', { className: 'proposal-detail-label' }, [
      'Implemented In: '
    ]),
    html('div', { className: 'proposal-detail-value' }, [
      `Swift ${version}`
    ])
  ])
}

/** For some proposal states like `.activeReview`, it helps to see the status in the same details list. */
function renderStatus (status) {
  return html('div', { className: 'proposal-detail' }, [
    html('div', { className: 'proposal-detail-label' }, [
      'Status: '
    ]),
    html('div', { className: 'proposal-detail-value' }, [
      states[status.state].name
    ])
  ])
}

/**
 * Review periods are ISO-8601-style 'YYYY-MM-DD' dates.
 */
function renderReviewPeriod (status) {
  const months = ['January', 'February', 'March', 'April', 'May', 'June', 'July',
    'August', 'September', 'October', 'November', 'December'
  ];

  const start = new Date(status.start);
  const end = new Date(status.end);

  const startMonth = start.getUTCMonth();
  const endMonth = end.getUTCMonth();

  const detailNodes = [months[startMonth], ' '];

  if (startMonth === endMonth) {
    detailNodes.push(
      start.getUTCDate().toString(),
      '–',
      end.getUTCDate().toString()
    )
  } else {
    detailNodes.push(
      start.getUTCDate().toString(),
      ' – ',
      months[endMonth],
      ' ',
      end.getUTCDate().toString()
    )
  }

  return html('div', { className: 'proposal-detail' }, [
    html('div', { className: 'proposal-detail-label' }, [
      'Scheduled: '
    ]),
    html('div', { className: 'proposal-detail-value' }, detailNodes)
  ])
}

/** Utility used by some of the `render*` functions to add comma text nodes between DOM nodes. */
function _joinNodes (nodeList, text) {
  return nodeList.map(node => [node, text]).reduce((result, pair, index, pairs) => {
    if (index === pairs.length - 1) pair.pop()
    return result.concat(pair)
  }, [])
}

/** Adds UI interactivity to the page. Primarily activates the filtering controls. */
function addEventListeners () {
  const nav = document.querySelector('nav');

  // typing in the search field causes the filter to be reapplied.
  nav.addEventListener('keyup', filterProposals)
  nav.addEventListener('change', filterProposals)

  // clearing the search field also hides the X symbol
  nav.querySelector('#clear-button').addEventListener('click', () => {
    nav.querySelector('#search-filter').value = ''
    nav.querySelector('#clear-button').classList.toggle('hidden')
    filterProposals()
  })

  // each of the individual statuses needs to trigger filtering as well
  ;[].forEach.call(nav.querySelectorAll('.filter-by-status input'), element => {
    element.addEventListener('change', filterProposals)
  })

  const expandableArea = document.querySelector('.filter-options');
  const implementedToggle = document.querySelector('#filter-by-implemented');
  implementedToggle.addEventListener('change', () => {
    // hide or show the row of version options depending on the status of the 'Implemented' option
    ;['#version-options', '#version-options-label'].forEach(selector => {
      expandableArea.querySelector(selector).classList.toggle('hidden')
    })

    // don't persist any version selections when the row is hidden
    ;[].concat(...expandableArea.querySelectorAll('.filter-by-swift-version')).forEach(versionCheckbox => {
      versionCheckbox.checked = false
    })
  })

  document.querySelector('.filter-button').addEventListener('click', toggleFiltering)

  const filterToggle = document.querySelector('.filter-toggle');
  filterToggle.querySelector('.toggle-filter-panel').addEventListener('click', toggleFilterPanel)

  // Behavior conditional on certain browser features
  const CSS = window.CSS;
  if (CSS) {
    // emulate position: sticky when it isn't available.
    if (!(CSS.supports('position', 'sticky') || CSS.supports('position', '-webkit-sticky'))) {
      window.addEventListener('scroll', () => {
        const breakpoint = document.querySelector('header').getBoundingClientRect().bottom;
        const nav = document.querySelector('nav');
        const position = window.getComputedStyle(nav).position;
        let shadowNav; // maintain the main content height when the main 'nav' is removed from the flow

        // this is measuring whether or not the header has scrolled offscreen
        if (breakpoint <= 0) {
          if (position !== 'fixed') {
            shadowNav = nav.cloneNode(true)
            shadowNav.classList.add('clone')
            shadowNav.style.visibility = 'hidden'
            nav.parentNode.insertBefore(shadowNav, document.querySelector('main'))
            nav.style.position = 'fixed'
          }
        } else if (position === 'fixed') {
          nav.style.position = 'static'
          shadowNav = document.querySelector('nav.clone')
          if (shadowNav) shadowNav.parentNode.removeChild(shadowNav)
        }
      })
    }
  }

  // on smaller screens, hide the filter panel when scrolling
  if (window.matchMedia('(max-width: 414px)').matches) {
    window.addEventListener('scroll', () => {
      const breakpoint = document.querySelector('header').getBoundingClientRect().bottom;
      if (breakpoint <= 0 && document.querySelector('.expandable').classList.contains('expanded')) {
        toggleFilterPanel()
      }
    })
  }
}

/**
 * Toggles whether filters are active. Rather than being cleared, they are saved to be restored later.
 * Additionally, toggles the presence of the "Filtered by:" status indicator.
 */
function toggleFiltering () {
  const filterDescription = document.querySelector('.filter-toggle');
  const shouldPreserveSelection = !filterDescription.classList.contains('hidden');

  filterDescription.classList.toggle('hidden')
  const selected = document.querySelectorAll('.filter-by-status input[type=checkbox]:checked');
  const filterButton = document.querySelector('.filter-button');

  if (shouldPreserveSelection) {
    filterSelection = [].map.call(selected, checkbox => checkbox.id)
    ;[].forEach.call(selected, checkbox => { checkbox.checked = false })

    filterButton.setAttribute('aria-pressed', 'false')
  } else { // restore it
    filterSelection.forEach(id => {
      const checkbox = document.getElementById(id);
      checkbox.checked = true
    })

    filterButton.setAttribute('aria-pressed', 'true')
  }

  document.querySelector('.expandable').classList.remove('expanded')
  filterButton.classList.toggle('active')

  filterProposals()
}

/**
 * Expands or constracts the filter panel, which contains buttons that
 * let users filter proposals based on their current stage in the
 * Swift Evolution process.
 */
function toggleFilterPanel () {
  const panel = document.querySelector('.expandable');
  const button = document.querySelector('.toggle-filter-panel');

  panel.classList.toggle('expanded')

  if (panel.classList.contains('expanded')) {
    button.setAttribute('aria-pressed', 'true')
  } else {
    button.setAttribute('aria-pressed', 'false')
  }
}

/**
 * Applies both the status-based and text-input based filters to the proposals list.
 */
function filterProposals () {
  const filterElement = document.querySelector('#search-filter');
  const filter = filterElement.value;

  const clearButton = document.querySelector('#clear-button');
  if (filter.length === 0) {
    clearButton.classList.add('hidden')
  } else {
    clearButton.classList.remove('hidden')
  }

  let matchingSets = [proposals.concat()];

  // Comma-separated lists of proposal IDs are treated as an "or" search.
  if (filter.match(/(SE-\d\d\d\d)($|((,SE-\d\d\d\d)+))/i)) {
    const proposalIDs = filter.split(',').map(id => id.toUpperCase());

    matchingSets[0] = matchingSets[0].filter(proposal => proposalIDs.includes(proposal.id))
  } else if (filter.trim().length !== 0) {
    // The search input treats words as order-independent.
    matchingSets = filter.split(/\s/)
      .filter(s => s.length > 0)
      .map(part => _searchProposals(part))
  }

  const intersection = matchingSets.reduce((intersection, candidates) => intersection.filter(alreadyIncluded => candidates.includes(alreadyIncluded)), matchingSets[0] || []);

  _applyFilter(intersection)
  _updateURIFragment()
}

/**
 * Utility used by `filterProposals`.
 *
 * Picks out various fields in a proposal which users may want to key
 * off of in their text-based filtering.
 *
 * @param {string} filterText - A raw word of text as entered by the user.
 * @returns {Proposal[]} The proposals that match the entered text, taken from the global list.
 */
function _searchProposals (filterText) {
  const filterExpression = filterText.toLowerCase();

  const searchableProperties = [
      ['id'],
      ['title'],
      ['reviewManager', 'name'],
      ['status', 'state'],
      ['status', 'version'],
      ['authors', 'name'],
      ['authors', 'link'],
      ['implementation', 'account'],
      ['implementation', 'repository'],
      ['implementation', 'id'],
      ['trackingBugs', 'link'],
      ['trackingBugs', 'status'],
      ['trackingBugs', 'id'],
      ['trackingBugs', 'assignee']
  ];

  // reflect over the proposals and find ones with matching properties
  const matchingProposals = proposals.filter(proposal => {
    let match = false;
    searchableProperties.forEach(propertyList => {
      let value = proposal;

      propertyList.forEach((propertyName, index) => {
        if (!value) return
        value = value[propertyName]
        if (index < propertyList.length - 1) {
          // For arrays, apply the property check to each child element.
          // Note that this only looks to a depth of one property.
          if (Array.isArray(value)) {
            const matchCondition = value.some(element => element[propertyList[index + 1]] && element[propertyList[index + 1]].toString().toLowerCase().includes(filterExpression));

            if (matchCondition) {
              match = true
            }
          } else {
            return
          }
        } else if (value && value.toString().toLowerCase().includes(filterExpression)) {
          match = true
        }
      })
    })

    return match
  });

  return matchingProposals
}

/**
 * Helper for `filterProposals` that actually makes the filter take effect.
 *
 * @param {Proposal[]} matchingProposals - The proposals that have passed the text filtering phase.
 * @returns {Void} Toggles `display: hidden` to apply the filter.
 */
function _applyFilter (matchingProposals) {
  // filter out proposals based on the grouping checkboxes
  const allStateCheckboxes = document.querySelector('nav').querySelectorAll('.filter-by-status input:checked');
  const selectedStates = [].map.call(allStateCheckboxes, checkbox => checkbox.value);

  const selectedStateNames = [].map.call(allStateCheckboxes, checkbox => checkbox.nextElementSibling.innerText.trim());
  updateFilterDescription(selectedStateNames)

  if (selectedStates.length) {
    matchingProposals = matchingProposals
      .filter(proposal => selectedStates.some(state => proposal.status.state.toLowerCase().includes(state.split('-')[0])))

    // handle version-specific filtering options
    if (selectedStates.some(state => state.match(/swift/i))) {
      matchingProposals = matchingProposals
        .filter(proposal => selectedStates.some(state => {
        if (!(proposal.status.state === '.implemented')) return true // only filter among Implemented (N.N.N)

        const version = state.split(/\D+/).filter(s => s.length).join('.');

        if (!version.length) return false // it's not a state that represents a version number
        if (proposal.status.version === version) return true
        return false
      }))
    }
  }

  const filteredProposals = proposals.filter(proposal => !matchingProposals.includes(proposal));

  matchingProposals.forEach(proposal => {
    const matchingElements = [].concat(...document.querySelectorAll(`.${proposal.id}`));
    matchingElements.forEach(element => { element.classList.remove('hidden') })
  })

  filteredProposals.forEach(proposal => {
    const filteredElements = [].concat(...document.querySelectorAll(`.${proposal.id}`));
    filteredElements.forEach(element => { element.classList.add('hidden') })
  })

  updateProposalsCount(matchingProposals.length)
}

/**
 * Parses a URI fragment and applies a search and filters to the page.
 *
 * Syntax (a query string within a fragment):
 *   fragment --> `#?` parameter-value-list
 *   parameter-value-list --> parameter-value | parameter-value-pair `&` parameter-value-list
 *   parameter-value-pair --> parameter `=` value
 *   parameter --> `proposal` | `status` | `version` | `search`
 *   value --> ** Any URL-encoded text. **
 *
 * For example:
 *   /#?proposal:SE-0180,SE-0123
 *   /#?status=rejected&version=3&search=access
 *
 * Four types of parameters are supported:
 * - proposal: A comma-separated list of proposal IDs. Treated as an 'or' search.
 * - filter: A comma-separated list of proposal statuses to apply as a filter.
 * - version: A comma-separated list of Swift version numbers to apply as a filter.
 * - search: Raw, URL-encoded text used to filter by individual term.
 *
 * @param {string} fragment - A URI fragment to use as the basis for a search.
 */
function _applyFragment (fragment) {
  if (!fragment || fragment.substr(0, 2) !== '#?') return
  fragment = fragment.substring(2) // remove the #?

  // use this literal's keys as the source of truth for key-value pairs in the fragment
  const actions = { proposal: [], search: null, status: [], version: [] };

  // parse the fragment as a query string
  Object.keys(actions).forEach(action => {
    const pattern = new RegExp(`${action}=([^=]+)(&|$)`);
    const values = fragment.match(pattern);

    if (values) {
      let value = values[1]; // 1st capture group from the RegExp
      if (action === 'search') {
        value = decodeURIComponent(value)
      } else {
        value = value.split(',')
      }

      actions[action] = value
    }
  })

  // perform key-specific parsing and checks

  if (actions.proposal.length) {
    document.querySelector('#search-filter').value = actions.proposal.join(',')
  } else if (actions.search) {
    document.querySelector('#search-filter').value = actions.search
  }

  if (actions.version.length) {
    const versionSelections = actions.version.map(version => document.querySelector(`#filter-by-swift-${_idSafeName(version)}`)).filter(version => !!version);

    versionSelections.forEach(versionSelection => {
      versionSelection.checked = true
    })

    if (versionSelections.length) {
      document.querySelector(
        `#filter-by-${states['.implemented'].className}`
      ).checked = true
    }
  }

  // track this state specifically for toggling the version panel
  let implementedSelected = false;

  // update the filter selections in the nav
  if (actions.status.length) {
    const statusSelections = actions.status.map(status => {
      const stateName = Object.keys(states).filter(state => states[state].className === status)[0];

      if (!stateName) return // fragment contains a nonexistent state
      const state = states[stateName];

      if (stateName === '.implemented') implementedSelected = true

      return document.querySelector(`#filter-by-${state.className}`)
    }).filter(status => !!status);

    statusSelections.forEach(statusSelection => {
      statusSelection.checked = true
    })
  }

  // the version panel needs to be activated if any are specified
  if (actions.version.length || implementedSelected) {
    ;['#version-options', '#version-options-label'].forEach(selector => {
      document.querySelector('.filter-options')
        .querySelector(selector).classList
        .toggle('hidden')
    })
  }

  // specifying any filter in the fragment should activate the filters in the UI
  if (actions.version.length || actions.status.length) {
    toggleFilterPanel()
    toggleFiltering()
  }

  filterProposals()
}

/**
 * Writes out the current search and filter settings to document.location
 * via window.replaceState.
 */
function _updateURIFragment () {
  const actions = { proposal: [], search: null, status: [], version: [] };

  const search = document.querySelector('#search-filter');

  if (search.value && search.value.match(/(SE-\d\d\d\d)($|((,SE-\d\d\d\d)+))/i)) {
    actions.proposal = search.value.toUpperCase().split(',')
  } else {
    actions.search = search.value
  }

  const selectedVersions = document.querySelectorAll('.filter-by-swift-version:checked');
  const versions = [].map.call(selectedVersions, checkbox => checkbox.value.split('swift-swift-')[1].split('-').join('.'));

  actions.version = versions

  const selectedStatuses = document.querySelectorAll('.filtered-by-status:checked');
  let statuses = [].map.call(selectedStatuses, checkbox => {
    const className = checkbox.value;

    const correspondingStatus = Object.keys(states).filter(status => {
      if (states[status].className === className) return true
      return false
    })[0];

    return states[correspondingStatus].className
  });

  // .implemented is redundant if any specific implementation versions are selected.
  if (actions.version.length) {
    statuses = statuses.filter(status => status !== states['.implemented'].className)
  }

  actions.status = statuses

  // build the actual fragment string.
  const fragments = [];
  if (actions.proposal.length) fragments.push(`proposal=${actions.proposal.join(',')}`)
  if (actions.status.length) fragments.push(`status=${actions.status.join(',')}`)
  if (actions.version.length) fragments.push(`version=${actions.version.join(',')}`)

  // encoding the search lets you search for `??` and other edge cases.
  if (actions.search) fragments.push(`search=${encodeURIComponent(actions.search)}`)

  if (!fragments.length) {
    window.history.replaceState(null, null, './')
    return
  }

  const fragment = `#?${fragments.join('&')}`;

  // avoid creating new history entries each time a search or filter updates
  window.history.replaceState(null, null, fragment)
}

/** Helper to give versions like 3.0.1 an okay ID to use in a DOM element. (swift-3-0-1) */
function _idSafeName (name) {
  return `swift-${name.replace(/\./g, '-')}`
}

/**
 * Changes the text after 'Filtered by: ' to reflect the current status filters.
 *
 * After FILTER_DESCRIPTION_LIMIT filters are explicitly named, start combining the descriptive text
 * to just state the number of status filters taking effect, not what they are.
 *
 * @param {string[]} selectedStateNames - CSS class names corresponding to which statuses were selected.
 * Populated from the global `stateNames` array.
 */
function updateFilterDescription (selectedStateNames) {
  let FILTER_DESCRIPTION_LIMIT = 2;
  const stateCount = selectedStateNames.length;

  // Limit the length of filter text on small screens.
  if (window.matchMedia('(max-width: 414px)').matches) {
    FILTER_DESCRIPTION_LIMIT = 1
  }

  const container = document.querySelector('.toggle-filter-panel');

  // modify the state names to clump together Implemented with version names
  const swiftVersionStates = selectedStateNames.filter(state => state.match(/swift/i));

  if (swiftVersionStates.length > 0 && swiftVersionStates.length <= FILTER_DESCRIPTION_LIMIT) {
    selectedStateNames = selectedStateNames.filter(state => !state.match(/swift|implemented/i))
      .concat(`Implemented (${swiftVersionStates.join(', ')})`)
  }

  if (selectedStateNames.length > FILTER_DESCRIPTION_LIMIT) {
    container.innerText = `${stateCount} Filters`
  } else if (selectedStateNames.length === 0) {
    container.innerText = 'All Statuses'
  } else {
    container.innerText = selectedStateNames.join(' or ')
  }
}

/** Updates the `${n} Proposals` display just above the proposals list. */
function updateProposalsCount (count) {
  const numberField = document.querySelector('#proposals-count-number');
  numberField.innerText = (`${count.toString()} proposal${count !== 1 ? 's' : ''}`)
}
